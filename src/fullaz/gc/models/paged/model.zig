const std = @import("std");
const gc = @import("../../gc.zig");
const interfaces = @import("../../interfaces.zig");
const PackedInt = @import("../../../core/packed_int.zig").PackedInt;
const storage_manager = @import("../../../core/storage_manager.zig");
const slot_queue = @import("../../../storage/slot_queue/slot_queue.zig");
const external_state = @import("state.zig");
const SlotQueue = slot_queue.SlotQueue;

/// A durable GC model with caller-owned transaction and external state root.
///
/// The caller persists the state-page root in its own root manager atomically
/// with the transaction. GC state, its mark/free bitmaps, and its FIFO are all
/// stored in pages allocated by that transaction.
///
/// `PageCacheT` owns raw page handles and `StorageManagerT` owns the durable
/// root plus page reservation and reclamation policy.
pub fn Paged(comptime PageCacheT: type, comptime StorageManagerT: type) type {
    return PagedWithKinds(
        PageCacheT,
        StorageManagerT,
        0x4740,
        0x4741,
        0x4742,
        0x4743,
    );
}

/// A durable GC model with explicit common page kinds for all private pages.
pub fn PagedWithKinds(
    comptime PageCacheT: type,
    comptime StorageManagerT: type,
    comptime state_page_kind: u16,
    comptime mark_bitmap_page_kind: u16,
    comptime free_bitmap_page_kind: u16,
    comptime queue_page_kind: u16,
) type {
    const state_magic = 0x4743_5354; // "GCST"
    const page_magic = 0x4743_5047; // "GCPG"
    const version = 2;
    const common_len = 16;
    const PackedPageId = PackedInt(PageCacheT.Pid, .little);
    const PackedCursor = PackedPageId;
    const PackedPageKind = PackedInt(u16, .little);
    const PackedU64 = PackedInt(u64, .little);
    const nil_page_id = PackedPageId.max;
    const QueueState = slot_queue.State(PageCacheT.Pid, u64, PageCacheT.Pid, .little);
    const ExternalState = external_state.State(PageCacheT.Pid);
    const ExternalStateLease = StorageManagerT.StateLeaseType;
    const ExternalStateView = storage_manager.StateAccessor(ExternalStateLease, ExternalState);

    const MetadataPageHeader = extern struct {
        kind: PackedPageKind,
        magic: PackedInt(u32, .little),
        role: u8,
        version: u8,
        next: PackedU64,
    };

    const StatePage = extern struct {
        kind: PackedPageKind,
        magic: PackedInt(u32, .little),
        role: u8,
        version: u8,
        phase: u8,
        reserved: u8,
        snapshot_page_count: PackedCursor,
        registry_digest: PackedU64,
        prepare_cursor: PackedCursor,
        sweep_cursor: PackedCursor,
        mark_head: PackedPageId,
        free_head: PackedPageId,
        queue: QueueState,
    };

    const metadata_header_len = @sizeOf(MetadataPageHeader);
    const state_len = @sizeOf(StatePage);

    comptime {
        if (state_page_kind == 0 or mark_bitmap_page_kind == 0 or
            free_bitmap_page_kind == 0 or queue_page_kind == 0 or
            state_page_kind == mark_bitmap_page_kind or
            state_page_kind == free_bitmap_page_kind or
            state_page_kind == queue_page_kind or
            mark_bitmap_page_kind == free_bitmap_page_kind or
            mark_bitmap_page_kind == queue_page_kind or
            free_bitmap_page_kind == queue_page_kind)
        {
            @compileError("GC private page kinds must be distinct and nonzero");
        }
        if (@alignOf(MetadataPageHeader) != 1 or metadata_header_len != common_len or
            @offsetOf(MetadataPageHeader, "kind") != 0 or
            @offsetOf(MetadataPageHeader, "magic") != @sizeOf(PackedPageKind) or
            @offsetOf(MetadataPageHeader, "next") != 8)
        {
            @compileError("GC metadata page layout changed");
        }
        if (@alignOf(StatePage) != 1 or state_len != 10 + 2 * @sizeOf(PackedU64) + 7 * @sizeOf(PackedPageId) or
            @offsetOf(StatePage, "kind") != 0 or
            @offsetOf(StatePage, "magic") != @sizeOf(PackedPageKind) or
            @offsetOf(StatePage, "phase") != 8 or
            @offsetOf(StatePage, "snapshot_page_count") != 10)
        {
            @compileError("GC state layout changed");
        }
        if (@offsetOf(QueueState, "page_chain") != 0 or
            @offsetOf(QueueState, "total_size") != 2 * @sizeOf(PackedPageId) or
            @sizeOf(QueueState) != 2 * @sizeOf(PackedPageId) + @sizeOf(PackedU64))
        {
            @compileError("GC queue state layout changed");
        }
    }

    const BaseError = PageCacheT.Error ||
        PageCacheT.Handle.Error ||
        StorageManagerT.Error ||
        ExternalStateLease.Error || error{
        BadData,
        TransactionInactive,
        InvalidState,
        InvalidPageId,
        StatePageTooSmall,
        InvalidMetadataPage,
    };

    comptime {
        interfaces.assertPagedPageCache(PageCacheT);
        interfaces.assertPagedStorageManager(StorageManagerT, PageCacheT.Pid);
    }

    const Role = enum(u8) {
        state = 1,
        mark_bitmap = 2,
        free_bitmap = 3,
    };

    return struct {
        const Self = @This();

        pub const PageId = PageCacheT.Pid;
        pub const Page = PageCacheT.Handle;
        pub const StatePageKind = state_page_kind;
        pub const MarkBitmapPageKind = mark_bitmap_page_kind;
        pub const FreeBitmapPageKind = free_bitmap_page_kind;
        pub const QueuePageKind = queue_page_kind;
        const QueueManager = struct {
            const QueueManagerSelf = @This();

            pub const PageId = PageCacheT.Pid;
            pub const Error = BaseError;
            pub const StateLeaseType = struct {
                const LeaseSelf = @This();

                pub const Error = BaseError;

                page: PageCacheT.Handle,

                pub fn data(self: *const LeaseSelf) LeaseSelf.Error![]const u8 {
                    const bytes = try self.page.data();
                    return bytes[@offsetOf(StatePage, "queue") .. @offsetOf(StatePage, "queue") + @sizeOf(QueueState)];
                }

                pub fn dataMut(self: *LeaseSelf) LeaseSelf.Error![]u8 {
                    const bytes = try self.page.dataMut();
                    return bytes[@offsetOf(StatePage, "queue") .. @offsetOf(StatePage, "queue") + @sizeOf(QueueState)];
                }

                pub fn finish(_: *LeaseSelf) void {}

                pub fn deinit(self: *LeaseSelf) void {
                    self.page.deinit();
                }
            };

            model: *Self,

            pub fn destroyPage(self: *QueueManagerSelf, page_id: QueueManagerSelf.PageId) QueueManagerSelf.Error!void {
                return self.model.storage.destroyPage(page_id);
            }

            pub fn state(self: *QueueManagerSelf) QueueManagerSelf.Error!StateLeaseType {
                const state_page_id = try self.model.statePageId();
                var page = try self.model.cache.fetch(state_page_id);
                errdefer page.deinit();
                const bytes = try page.data();
                try self.model.validateStateBytes(bytes);
                return .{ .page = page };
            }
        };

        const Queue = SlotQueue(PageCacheT, QueueManager, u64, PageCacheT.Pid, .little);

        pub const Error = BaseError || Queue.Error;

        allocator_value: std.mem.Allocator,
        cache: *PageCacheT,
        storage: *StorageManagerT,
        phase_value: gc.Phase = .idle,

        pub fn init(
            allocator_value: std.mem.Allocator,
            cache: *PageCacheT,
            storage: *StorageManagerT,
        ) Error!Self {
            var self = Self{
                .allocator_value = allocator_value,
                .cache = cache,
                .storage = storage,
            };
            try self.requireTransaction();
            if (try self.getStatePageRoot()) |page_id| {
                self.phase_value = try self.readPhase(page_id);
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn allocator(self: *const Self) std.mem.Allocator {
            return self.allocator_value;
        }

        pub fn isCycleActive(self: *const Self) bool {
            return self.phase_value != .idle;
        }

        pub fn beginCycle(self: *Self, registry_digest: u64) Error!usize {
            try self.requireTransaction();
            if (self.isCycleActive()) {
                const state_page_id = try self.statePageId();
                var page = try self.cache.fetch(state_page_id);
                defer page.deinit();
                const bytes = try page.data();
                try self.validateStateBytes(bytes);
                return @intCast((try self.stateView(bytes)).snapshot_page_count.get());
            }

            const state_page_id = try self.ensureStatePage();
            const snapshot_page_count = self.cache.pageCount();
            {
                var page = try self.cache.fetch(state_page_id);
                defer page.deinit();
                const state = try self.stateMut(try page.dataMut());
                state.snapshot_page_count.set(@intCast(snapshot_page_count));
                state.registry_digest.set(registry_digest);
                state.prepare_cursor.set(0);
                state.sweep_cursor.set(0);
            }
            try self.clearBitmap(state_page_id, .mark_bitmap);
            try self.clearBitmap(state_page_id, .free_bitmap);
            try self.clearQueue();
            try self.setPhase(.preparing);
            return snapshot_page_count;
        }

        pub fn phase(self: *const Self) gc.Phase {
            return self.phase_value;
        }

        pub fn setPhase(self: *Self, phase_value: gc.Phase) Error!void {
            try self.requireTransaction();
            const state_page_id = try self.statePageId();
            var page = try self.cache.fetch(state_page_id);
            defer page.deinit();
            const state = try self.stateMut(try page.dataMut());
            state.phase = @intFromEnum(phase_value);
            self.phase_value = phase_value;
        }

        pub fn registryDigest(self: *const Self) Error!u64 {
            try self.requireTransaction();
            const state_page_id = try self.statePageId();
            var page = try self.cache.fetch(state_page_id);
            defer page.deinit();
            const bytes = try page.data();
            try self.validateStateBytes(bytes);
            const state = try self.stateView(bytes);
            return state.registry_digest.get();
        }

        pub fn snapshotPageCount(self: *const Self) Error!usize {
            try self.requireTransaction();
            const state_page_id = try self.statePageId();
            var page = try self.cache.fetch(state_page_id);
            defer page.deinit();
            const bytes = try page.data();
            try self.validateStateBytes(bytes);
            const state = try self.stateView(bytes);
            return @intCast(state.snapshot_page_count.get());
        }

        pub fn prepare(self: *Self, maximum_step_pages: usize) Error!bool {
            try self.requireTransaction();
            const state_page_id = try self.statePageId();
            const progress = blk: {
                var page = try self.cache.fetch(state_page_id);
                defer page.deinit();
                const bytes = try page.data();
                try self.validateStateBytes(bytes);
                const state = try self.stateView(bytes);
                break :blk .{
                    .snapshot_page_count = @as(usize, @intCast(state.snapshot_page_count.get())),
                    .prepare_cursor = @as(usize, @intCast(state.prepare_cursor.get())),
                };
            };
            const snapshot_page_count = progress.snapshot_page_count;
            var cursor = progress.prepare_cursor;
            const end = @min(cursor +| maximum_step_pages, snapshot_page_count);
            const free_root = blk: {
                var page = try self.cache.fetch(state_page_id);
                defer page.deinit();
                const bytes = try page.data();
                try self.validateStateBytes(bytes);
                break :blk (try self.stateView(bytes)).free_head.get();
            };
            while (cursor < end) : (cursor += 1) {
                const page_id = std.math.cast(PageId, cursor) orelse return error.InvalidPageId;
                if (try self.storage.isFree(page_id)) {
                    try self.setBitmapBit(free_root, .free_bitmap, page_id);
                }
            }
            var page = try self.cache.fetch(state_page_id);
            defer page.deinit();
            const bytes = try page.dataMut();
            try self.validateStateBytes(bytes);
            (try self.stateMut(bytes)).prepare_cursor.set(@intCast(cursor));
            return cursor == snapshot_page_count;
        }

        pub fn mark(self: *Self, page_id: PageId) Error!bool {
            try self.requireTransaction();
            try self.validatePageId(page_id);
            const state_page_id = try self.statePageId();
            const mark_root = blk: {
                var page = try self.cache.fetch(state_page_id);
                defer page.deinit();
                const bytes = try page.data();
                try self.validateStateBytes(bytes);
                break :blk (try self.stateView(bytes)).mark_head.get();
            };
            if (try self.bitmapBit(mark_root, .mark_bitmap, page_id)) {
                return false;
            }
            try self.setBitmapBit(mark_root, .mark_bitmap, page_id);
            return true;
        }

        pub fn isMarked(self: *const Self, page_id: PageId) Error!bool {
            try self.requireTransaction();
            try self.validatePageId(page_id);
            const state_page_id = try self.statePageId();
            var page = try self.cache.fetch(state_page_id);
            defer page.deinit();
            const bytes = try page.data();
            try self.validateStateBytes(bytes);
            const state = try self.stateView(bytes);
            return self.bitmapBit(state.mark_head.get(), .mark_bitmap, page_id);
        }

        pub fn enqueue(self: *Self, page_id: PageId) Error!void {
            try self.requireTransaction();
            var manager = QueueManager{ .model = self };
            var queue = try Queue.init(
                self.cache,
                &manager,
                .{ .chunk_page_kind = queue_page_kind },
            );
            defer queue.deinit();
            const packed_page_id = PackedPageId.init(page_id);
            try queue.enqueue(&packed_page_id.bytes);
        }

        pub fn dequeue(self: *Self) Error!?PageId {
            try self.requireTransaction();
            var manager = QueueManager{ .model = self };
            var queue = try Queue.init(
                self.cache,
                &manager,
                .{ .chunk_page_kind = queue_page_kind },
            );
            defer queue.deinit();
            const page_id = blk: {
                var front = queue.front() catch |err| switch (err) {
                    error.EmptySet => return null,
                    else => return err,
                };
                defer front.deinit();
                const value = try front.value();
                if (value.len != @sizeOf(PageId)) {
                    return error.InvalidState;
                }
                const packed_page_id = PackedPageId.fromSlice(value) catch return error.InvalidState;
                break :blk packed_page_id.get();
            };
            try queue.dequeue();
            return page_id;
        }

        pub fn fetchPage(self: *Self, page_id: PageId) Error!Page {
            try self.requireTransaction();
            return self.cache.fetch(page_id);
        }

        pub fn releasePage(_: *Self, page: *Page) void {
            page.deinit();
        }

        pub fn pageKind(self: *Self, page: *Page, page_id: PageId) Error!u16 {
            try self.requireTransaction();
            _ = page_id;
            const bytes = try page.data();
            if (bytes.len < @sizeOf(u16)) {
                return error.InvalidState;
            }
            return std.mem.readInt(u16, bytes[0..@sizeOf(u16)], .little);
        }

        pub fn pageData(self: *Self, page: *Page) Error![]const u8 {
            try self.requireTransaction();
            return page.data();
        }

        pub fn sweepCursor(self: *const Self) Error!PageId {
            try self.requireTransaction();
            const state_page_id = try self.statePageId();
            var page = try self.cache.fetch(state_page_id);
            defer page.deinit();
            const bytes = try page.data();
            try self.validateStateBytes(bytes);
            const state = try self.stateView(bytes);
            return state.sweep_cursor.get();
        }

        pub fn setSweepCursor(self: *Self, page_id: PageId) Error!void {
            try self.requireTransaction();
            const state_page_id = try self.statePageId();
            var page = try self.cache.fetch(state_page_id);
            defer page.deinit();
            const bytes = try page.dataMut();
            try self.validateStateBytes(bytes);
            (try self.stateMut(bytes)).sweep_cursor.set(page_id);
        }

        pub fn isReserved(self: *Self, page_id: PageId) Error!bool {
            try self.requireTransaction();
            return self.storage.isReserved(page_id) or try self.isMetadataPage(page_id);
        }

        pub fn isFree(self: *Self, page_id: PageId) Error!bool {
            try self.requireTransaction();
            try self.validatePageId(page_id);
            const state_page_id = try self.statePageId();
            var page = try self.cache.fetch(state_page_id);
            defer page.deinit();
            const bytes = try page.data();
            try self.validateStateBytes(bytes);
            if (self.phase_value == .preparing or self.phase_value == .sweeping) {
                return self.storage.isFree(page_id);
            }
            return self.bitmapBit((try self.stateView(bytes)).free_head.get(), .free_bitmap, page_id);
        }

        pub fn reclaim(self: *Self, page_id: PageId) Error!void {
            try self.requireTransaction();
            return self.storage.destroyPage(page_id);
        }

        pub fn finishCycle(self: *Self) Error!void {
            return self.abortCycle();
        }

        /// Discards pending traversal work and returns the durable state to idle.
        pub fn abortCycle(self: *Self) Error!void {
            try self.requireTransaction();
            if (try self.getStatePageRoot() == null) {
                self.phase_value = .idle;
                return;
            }
            try self.clearQueue();
            try self.setPhase(.idle);
        }

        fn requireTransaction(self: *const Self) BaseError!void {
            if (!self.cache.transactionActive()) {
                return error.TransactionInactive;
            }
        }

        fn ensureStatePage(self: *Self) BaseError!PageId {
            if (try self.getStatePageRoot()) |page_id| {
                try self.validateStatePage(page_id);
                return page_id;
            }
            var page = try self.cache.create();
            defer page.deinit();
            const page_id = try page.pid();
            const bytes = try page.dataMut();
            if (bytes.len < state_len) {
                return error.StatePageTooSmall;
            }
            @memset(bytes, 0);
            const state = try self.stateMut(bytes);
            state.* = .{
                .kind = .init(state_page_kind),
                .magic = .init(state_magic),
                .role = @intFromEnum(Role.state),
                .version = version,
                .phase = @intFromEnum(gc.Phase.idle),
                .reserved = 0,
                .snapshot_page_count = .init(0),
                .registry_digest = .init(0),
                .prepare_cursor = .init(0),
                .sweep_cursor = .init(0),
                .mark_head = .init(nil_page_id),
                .free_head = .init(nil_page_id),
                .queue = .{},
            };
            try self.setStatePageRoot(page_id);
            return page_id;
        }

        fn statePageId(self: *const Self) BaseError!PageId {
            const page_id = (try self.getStatePageRoot()) orelse return error.InvalidState;
            try self.validateStatePage(page_id);
            return page_id;
        }

        fn getStatePageRoot(self: *const Self) BaseError!?PageId {
            var lease = try self.storage.state();
            defer lease.deinit();
            const state = try ExternalStateView.view(&lease);
            const page_id = state.state_page_root.get();
            return if (page_id == nil_page_id) null else page_id;
        }

        fn setStatePageRoot(self: *Self, page_id: ?PageId) BaseError!void {
            var lease = try self.storage.state();
            defer lease.deinit();
            const state = try ExternalStateView.viewMut(&lease);
            state.state_page_root.set(page_id orelse nil_page_id);
            lease.finish();
        }

        fn readPhase(self: *const Self, page_id: PageId) BaseError!gc.Phase {
            var page = try self.cache.fetch(page_id);
            defer page.deinit();
            const bytes = try page.data();
            try self.validateStateBytes(bytes);
            return switch ((try self.stateView(bytes)).phase) {
                @intFromEnum(gc.Phase.idle) => .idle,
                @intFromEnum(gc.Phase.preparing) => .preparing,
                @intFromEnum(gc.Phase.marking) => .marking,
                @intFromEnum(gc.Phase.sweeping) => .sweeping,
                else => error.InvalidState,
            };
        }

        fn validateStatePage(self: *const Self, page_id: PageId) BaseError!void {
            _ = try self.readPhase(page_id);
        }

        fn validateStateBytes(self: *const Self, bytes: []const u8) BaseError!void {
            const state = try self.stateView(bytes);
            if (state.kind.get() != state_page_kind or
                state.magic.get() != state_magic or
                state.role != @intFromEnum(Role.state) or state.version != version)
            {
                return error.InvalidState;
            }
        }

        fn stateView(_: *const Self, bytes: []const u8) BaseError!*const StatePage {
            if (bytes.len < state_len) {
                return error.InvalidState;
            }
            return @ptrCast(bytes.ptr);
        }

        fn stateMut(_: *Self, bytes: []u8) BaseError!*StatePage {
            if (bytes.len < state_len) {
                return error.InvalidState;
            }
            return @ptrCast(bytes.ptr);
        }

        fn clearBitmap(self: *Self, state_page_id: PageId, role: Role) BaseError!void {
            var head_id: PageId = undefined;
            {
                var state = try self.cache.fetch(state_page_id);
                defer state.deinit();
                const bytes = try state.dataMut();
                try self.validateStateBytes(bytes);
                const state_view = try self.stateMut(bytes);
                const stored_head = switch (role) {
                    .mark_bitmap => state_view.mark_head.get(),
                    .free_bitmap => state_view.free_head.get(),
                    .state => return error.InvalidState,
                };
                if (stored_head == nil_page_id) {
                    head_id = try self.createMetadataPage(role);
                    switch (role) {
                        .mark_bitmap => state_view.mark_head.set(head_id),
                        .free_bitmap => state_view.free_head.set(head_id),
                        .state => return error.InvalidState,
                    }
                } else {
                    head_id = stored_head;
                }
            }
            var current: ?PageId = head_id;
            while (current) |page_id| {
                var page = try self.cache.fetch(page_id);
                defer page.deinit();
                const bytes = try page.dataMut();
                try self.validateMetadata(bytes, role);
                const next = try self.nextPageId(bytes);
                @memset(bytes[common_len..], 0);
                current = next;
            }
        }

        fn bitmapBit(self: *const Self, root_id: PageId, role: Role, page_id: PageId) BaseError!bool {
            const byte_index: usize = @intCast(page_id / 8);
            var current_id = root_id;
            var page_index: usize = 0;
            const target_index = byte_index / self.bitmapBytesPerPage();
            while (page_index < target_index) : (page_index += 1) {
                var current = try self.cache.fetch(current_id);
                defer current.deinit();
                const current_bytes = try current.data();
                try self.validateMetadata(current_bytes, role);
                current_id = (try self.nextPageId(current_bytes)) orelse return false;
            }
            var page = try self.cache.fetch(current_id);
            defer page.deinit();
            const bytes = try page.data();
            try self.validateMetadata(bytes, role);
            return (bytes[common_len + byte_index % self.bitmapBytesPerPage()] & (@as(u8, 1) << @intCast(page_id % 8))) != 0;
        }

        fn setBitmapBit(self: *Self, root_id: PageId, role: Role, page_id: PageId) BaseError!void {
            const byte_index: usize = @intCast(page_id / 8);
            var page = try self.bitmapPage(
                root_id,
                role,
                byte_index / self.bitmapBytesPerPage(),
                true,
            );
            defer page.deinit();
            const bytes = try page.dataMut();
            bytes[common_len + byte_index % self.bitmapBytesPerPage()] |= @as(u8, 1) << @intCast(page_id % 8);
        }

        fn bitmapPage(
            self: *Self,
            root_id: PageId,
            role: Role,
            page_index: usize,
            create: bool,
        ) BaseError!Page {
            var current_id = root_id;
            var index: usize = 0;
            while (index < page_index) : (index += 1) {
                var current = try self.cache.fetch(current_id);
                const bytes = try current.dataMut();
                try self.validateMetadata(bytes, role);
                var next = try self.nextPageId(bytes);
                if (next == null and create) {
                    next = try self.createMetadataPage(role);
                    (try metadataHeaderMut(bytes)).next.set(@intCast(next.?));
                }
                current.deinit();
                current_id = next orelse return error.InvalidState;
            }
            const page = try self.cache.fetch(current_id);
            const bytes = try page.data();
            self.validateMetadata(bytes, role) catch |err| {
                @constCast(&page).deinit();
                return err;
            };
            return page;
        }

        fn clearQueue(self: *Self) Error!void {
            var manager = QueueManager{ .model = self };
            var queue = try Queue.init(
                self.cache,
                &manager,
                .{ .chunk_page_kind = queue_page_kind },
            );
            defer queue.deinit();
            while (!try queue.isEmpty()) {
                try queue.dequeue();
            }
        }

        fn createMetadataPage(self: *Self, role: Role) BaseError!PageId {
            var page = try self.cache.create();
            defer page.deinit();
            const bytes = try page.dataMut();
            if (bytes.len < common_len) {
                return error.StatePageTooSmall;
            }
            @memset(bytes, 0);
            (try metadataHeaderMut(bytes)).* = .{
                .kind = .init(self.metadataPageKind(role)),
                .magic = .init(page_magic),
                .role = @intFromEnum(role),
                .version = version,
                .next = .init(0),
            };
            return page.pid();
        }

        fn isMetadataPage(self: *Self, page_id: PageId) Error!bool {
            var page = try self.cache.fetch(page_id);
            defer page.deinit();
            const bytes = try page.data();
            if (bytes.len < common_len) {
                return false;
            }
            const header = try metadataHeaderView(bytes);
            if (header.kind.get() == state_page_kind) {
                return header.magic.get() == state_magic and
                    header.role == @intFromEnum(Role.state) and
                    header.version == version;
            }
            if (header.kind.get() == mark_bitmap_page_kind) {
                return header.magic.get() == page_magic and
                    header.role == @intFromEnum(Role.mark_bitmap) and
                    header.version == version;
            }
            if (header.kind.get() == free_bitmap_page_kind) {
                return header.magic.get() == page_magic and
                    header.role == @intFromEnum(Role.free_bitmap) and
                    header.version == version;
            }
            if (header.kind.get() != queue_page_kind) {
                return false;
            }
            return self.isQueuePage(page_id, bytes);
        }

        fn validatePageId(self: *const Self, page_id: PageId) BaseError!void {
            const state_page_id = try self.statePageId();
            var page = try self.cache.fetch(state_page_id);
            defer page.deinit();
            const bytes = try page.data();
            try self.validateStateBytes(bytes);
            if (page_id >= (try self.stateView(bytes)).snapshot_page_count.get()) {
                return error.InvalidPageId;
            }
        }

        fn validateMetadata(self: *const Self, bytes: []const u8, role: Role) BaseError!void {
            if (bytes.len < metadata_header_len) {
                return error.InvalidMetadataPage;
            }
            const header = try metadataHeaderView(bytes);
            if (header.kind.get() != self.metadataPageKind(role) or
                header.magic.get() != page_magic or
                header.role != @intFromEnum(role) or header.version != version)
            {
                return error.InvalidMetadataPage;
            }
        }

        fn nextPageId(_: *const Self, bytes: []const u8) BaseError!?PageId {
            const value = (try metadataHeaderView(bytes)).next.get();
            if (value == 0) {
                return null;
            }
            return std.math.cast(PageId, value) orelse error.InvalidState;
        }

        fn bitmapBytesPerPage(self: *const Self) usize {
            return self.cache.pageSize() - common_len;
        }

        fn metadataPageKind(_: *const Self, role: Role) u16 {
            return switch (role) {
                .mark_bitmap => mark_bitmap_page_kind,
                .free_bitmap => free_bitmap_page_kind,
                .state => unreachable,
            };
        }

        fn isQueuePage(self: *Self, page_id: PageId, bytes: []const u8) Error!bool {
            const Validator = struct {
                pub fn hasValueScanner(_: @This()) bool {
                    return false;
                }

                pub fn visit(_: @This(), _: PageId) error{}!void {}

                pub fn visitValue(_: @This(), _: []const u8) error{}!void {}
            };
            var manager = QueueManager{ .model = self };
            var queue = try Queue.init(
                self.cache,
                &manager,
                .{ .chunk_page_kind = queue_page_kind },
            );
            defer queue.deinit();
            queue.scanChunkRefs(page_id, bytes, Validator{}) catch return false;
            return true;
        }

        fn metadataHeaderView(bytes: []const u8) BaseError!*const MetadataPageHeader {
            if (bytes.len < metadata_header_len) {
                return error.InvalidState;
            }
            return @ptrCast(bytes.ptr);
        }

        fn metadataHeaderMut(bytes: []u8) BaseError!*MetadataPageHeader {
            if (bytes.len < metadata_header_len) {
                return error.InvalidState;
            }
            return @ptrCast(bytes.ptr);
        }
    };
}
