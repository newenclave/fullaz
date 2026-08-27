const std = @import("std");
const gc = @import("../../gc.zig");
const interfaces = @import("../../interfaces.zig");
const PackedInt = @import("../../../core/packed_int.zig").PackedInt;
const SlotQueue = @import("../../../storage/slot_queue/slot_queue.zig").SlotQueue;

/// A durable GC model with caller-owned transaction and external state root.
///
/// The caller persists the state-page root in its own root manager atomically
/// with the transaction. GC state, its mark/free bitmaps, and its FIFO are all
/// stored in pages allocated by that transaction.
///
/// `PageCacheT` owns raw page handles and `StorageManagerT` owns the durable
/// root plus page reservation and reclamation policy.
pub fn Paged(comptime PageCacheT: type, comptime StorageManagerT: type) type {
    const state_magic = 0x4743_5354; // "GCST"
    const page_magic = 0x4743_5047; // "GCPG"
    const version = 1;
    const state_len = 80;
    const common_len = 16;
    const queue_page_kind = 0x4743; // "GC"
    const PackedPageId = PackedInt(PageCacheT.Pid, .little);

    const BaseError = PageCacheT.Error ||
        PageCacheT.Handle.Error ||
        StorageManagerT.Error || error{
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
        const QueueManager = struct {
            const QueueManagerSelf = @This();

            pub const PageId = PageCacheT.Pid;
            pub const Size = u64;
            pub const Error = BaseError;

            model: *Self,

            pub fn destroyPage(self: *QueueManagerSelf, page_id: QueueManagerSelf.PageId) QueueManagerSelf.Error!void {
                return self.model.storage.destroyPage(page_id);
            }

            pub fn getFirst(self: *const QueueManagerSelf) QueueManagerSelf.Error!?QueueManagerSelf.PageId {
                return self.model.stateOptionalPageId(.queue_first);
            }

            pub fn setFirst(self: *QueueManagerSelf, page_id: ?QueueManagerSelf.PageId) QueueManagerSelf.Error!void {
                try self.model.setStateOptionalPageId(.queue_first, page_id);
            }

            pub fn getLast(self: *const QueueManagerSelf) QueueManagerSelf.Error!?QueueManagerSelf.PageId {
                return self.model.stateOptionalPageId(.queue_last);
            }

            pub fn setLast(self: *QueueManagerSelf, page_id: ?QueueManagerSelf.PageId) QueueManagerSelf.Error!void {
                try self.model.setStateOptionalPageId(.queue_last, page_id);
            }

            pub fn getTotalSize(self: *const QueueManagerSelf) QueueManagerSelf.Error!QueueManagerSelf.Size {
                return self.model.stateU64(.queue_total_size);
            }

            pub fn setTotalSize(self: *QueueManagerSelf, size: QueueManagerSelf.Size) QueueManagerSelf.Error!void {
                try self.model.setStateU64(
                    try self.model.statePageId(),
                    .queue_total_size,
                    size,
                );
            }
        };

        const Queue = SlotQueue(PageCacheT, QueueManager, .little);

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
            if (storage.getRoot()) |page_id| {
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
                return try self.stateUsize(.snapshot_page_count);
            }

            const state_page_id = try self.ensureStatePage();
            const snapshot_page_count = self.cache.pageCount();
            try self.setStateU64(state_page_id, .snapshot_page_count, snapshot_page_count);
            try self.setStateU64(state_page_id, .registry_digest, registry_digest);
            try self.setStateU64(state_page_id, .prepare_cursor, 0);
            try self.setStateU64(state_page_id, .sweep_cursor, 0);
            try self.clearBitmap(state_page_id, .mark_head, .mark_bitmap);
            try self.clearBitmap(state_page_id, .free_head, .free_bitmap);
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
            try self.setStateByte(state_page_id, 6, @intFromEnum(phase_value));
            self.phase_value = phase_value;
        }

        pub fn registryDigest(self: *const Self) u64 {
            return self.stateU64(.registry_digest) catch 0;
        }

        pub fn snapshotPageCount(self: *const Self) usize {
            return self.stateUsize(.snapshot_page_count) catch 0;
        }

        pub fn prepare(self: *Self, maximum_step_pages: usize) Error!bool {
            try self.requireTransaction();
            const state_page_id = try self.statePageId();
            const snapshot_page_count = try self.stateUsize(.snapshot_page_count);
            var cursor = try self.stateUsize(.prepare_cursor);
            const end = @min(cursor +| maximum_step_pages, snapshot_page_count);
            while (cursor < end) : (cursor += 1) {
                const page_id = std.math.cast(PageId, cursor) orelse return error.InvalidPageId;
                if (try self.storage.isFree(page_id)) {
                    try self.setBitmapBit(state_page_id, .free_head, .free_bitmap, page_id);
                }
            }
            try self.setStateU64(state_page_id, .prepare_cursor, cursor);
            return cursor == snapshot_page_count;
        }

        pub fn mark(self: *Self, page_id: PageId) Error!bool {
            try self.requireTransaction();
            try self.validatePageId(page_id);
            const state_page_id = try self.statePageId();
            if (try self.bitmapBit(state_page_id, .mark_head, .mark_bitmap, page_id)) {
                return false;
            }
            try self.setBitmapBit(state_page_id, .mark_head, .mark_bitmap, page_id);
            return true;
        }

        pub fn isMarked(self: *const Self, page_id: PageId) bool {
            const state_page_id = self.storage.getRoot() orelse return false;
            return self.bitmapBit(state_page_id, .mark_head, .mark_bitmap, page_id) catch false;
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

        pub fn sweepCursor(self: *const Self) PageId {
            return std.math.cast(PageId, self.stateUsize(.sweep_cursor) catch 0) orelse 0;
        }

        pub fn setSweepCursor(self: *Self, page_id: PageId) Error!void {
            try self.requireTransaction();
            try self.setStateU64(try self.statePageId(), .sweep_cursor, page_id);
        }

        pub fn isReserved(self: *Self, page_id: PageId) Error!bool {
            try self.requireTransaction();
            return self.storage.isReserved(page_id) or try self.isMetadataPage(page_id);
        }

        pub fn isFree(self: *Self, page_id: PageId) Error!bool {
            try self.requireTransaction();
            try self.validatePageId(page_id);
            return self.bitmapBit(try self.statePageId(), .free_head, .free_bitmap, page_id);
        }

        pub fn reclaim(self: *Self, page_id: PageId) Error!void {
            try self.requireTransaction();
            return self.storage.destroyPage(page_id);
        }

        pub fn finishCycle(self: *Self) Error!void {
            try self.requireTransaction();
            try self.clearQueue();
            try self.setPhase(.idle);
        }

        const StateField = enum {
            snapshot_page_count,
            registry_digest,
            prepare_cursor,
            sweep_cursor,
            mark_head,
            free_head,
            queue_first,
            queue_last,
            queue_total_size,
        };

        fn stateOffset(field: StateField) usize {
            return switch (field) {
                .snapshot_page_count => 8,
                .registry_digest => 16,
                .prepare_cursor => 24,
                .sweep_cursor => 32,
                .mark_head => 40,
                .free_head => 48,
                .queue_first => 56,
                .queue_last => 64,
                .queue_total_size => 72,
            };
        }

        fn requireTransaction(self: *const Self) BaseError!void {
            if (!self.cache.transactionActive()) {
                return error.TransactionInactive;
            }
        }

        fn ensureStatePage(self: *Self) BaseError!PageId {
            if (self.storage.getRoot()) |page_id| {
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
            try writeU32(bytes, 0, state_magic);
            bytes[4] = @intFromEnum(Role.state);
            bytes[5] = version;
            bytes[6] = @intFromEnum(gc.Phase.idle);
            try self.storage.setRoot(page_id);
            return page_id;
        }

        fn statePageId(self: *const Self) BaseError!PageId {
            const page_id = self.storage.getRoot() orelse return error.InvalidState;
            try self.validateStatePage(page_id);
            return page_id;
        }

        fn readPhase(self: *const Self, page_id: PageId) BaseError!gc.Phase {
            var page = try self.cache.fetch(page_id);
            defer page.deinit();
            const bytes = try page.data();
            try self.validateStateBytes(bytes);
            return switch (bytes[6]) {
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

        fn validateStateBytes(_: *const Self, bytes: []const u8) BaseError!void {
            if (bytes.len < state_len or try readU32(bytes, 0) != state_magic or
                bytes[4] != @intFromEnum(Role.state) or bytes[5] != version)
            {
                return error.InvalidState;
            }
        }

        fn stateU64(self: *const Self, field: StateField) BaseError!u64 {
            var page = try self.cache.fetch(try self.statePageId());
            defer page.deinit();
            const bytes = try page.data();
            try self.validateStateBytes(bytes);
            return readU64(bytes, stateOffset(field));
        }

        fn stateUsize(self: *const Self, field: StateField) BaseError!usize {
            return @intCast(try self.stateU64(field));
        }

        fn setStateU64(self: *Self, state_page_id: PageId, field: StateField, value: anytype) BaseError!void {
            var page = try self.cache.fetch(state_page_id);
            defer page.deinit();
            const bytes = try page.dataMut();
            try self.validateStateBytes(bytes);
            try writeU64(bytes, stateOffset(field), @intCast(value));
        }

        fn setStateByte(self: *Self, state_page_id: PageId, offset: usize, value: u8) BaseError!void {
            var page = try self.cache.fetch(state_page_id);
            defer page.deinit();
            const bytes = try page.dataMut();
            try self.validateStateBytes(bytes);
            bytes[offset] = value;
        }

        fn statePageIdField(self: *const Self, state_page_id: PageId, field: StateField) BaseError!PageId {
            var page = try self.cache.fetch(state_page_id);
            defer page.deinit();
            const bytes = try page.data();
            try self.validateStateBytes(bytes);
            return readPageId(bytes, stateOffset(field));
        }

        fn setStatePageId(self: *Self, state_page_id: PageId, field: StateField, page_id: PageId) BaseError!void {
            var page = try self.cache.fetch(state_page_id);
            defer page.deinit();
            const bytes = try page.dataMut();
            try self.validateStateBytes(bytes);
            try writePageId(bytes, stateOffset(field), page_id);
        }

        fn stateOptionalPageId(self: *const Self, field: StateField) BaseError!?PageId {
            const value = try self.stateU64(field);
            if (value == 0) {
                return null;
            }
            return try pageIdFromU64(value);
        }

        fn setStateOptionalPageId(self: *Self, field: StateField, page_id: ?PageId) BaseError!void {
            try self.setStateU64(
                try self.statePageId(),
                field,
                if (page_id) |value| value else 0,
            );
        }

        fn clearBitmap(self: *Self, state_page_id: PageId, field: StateField, role: Role) BaseError!void {
            var head_id: PageId = undefined;
            {
                var state = try self.cache.fetch(state_page_id);
                defer state.deinit();
                const bytes = try state.dataMut();
                try self.validateStateBytes(bytes);
                const stored_head = try readU64(bytes, stateOffset(field));
                if (stored_head == 0) {
                    head_id = try self.createMetadataPage(role);
                    try writePageId(bytes, stateOffset(field), head_id);
                } else {
                    head_id = try pageIdFromU64(stored_head);
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

        fn bitmapBit(self: *const Self, state_page_id: PageId, field: StateField, role: Role, page_id: PageId) BaseError!bool {
            const byte_index: usize = @intCast(page_id / 8);
            var current_id = try self.statePageIdField(state_page_id, field);
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

        fn setBitmapBit(self: *Self, state_page_id: PageId, field: StateField, role: Role, page_id: PageId) BaseError!void {
            const byte_index: usize = @intCast(page_id / 8);
            var page = try self.bitmapPage(
                state_page_id,
                field,
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
            state_page_id: PageId,
            field: StateField,
            role: Role,
            page_index: usize,
            create: bool,
        ) BaseError!Page {
            var current_id = try self.statePageIdField(state_page_id, field);
            var index: usize = 0;
            while (index < page_index) : (index += 1) {
                var current = try self.cache.fetch(current_id);
                const bytes = try current.dataMut();
                try self.validateMetadata(bytes, role);
                var next = try self.nextPageId(bytes);
                if (next == null and create) {
                    next = try self.createMetadataPage(role);
                    try writePageId(bytes, 8, next.?);
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
            try writeU32(bytes, 0, page_magic);
            bytes[4] = @intFromEnum(role);
            bytes[5] = version;
            return page.pid();
        }

        fn isMetadataPage(self: *Self, page_id: PageId) BaseError!bool {
            var page = self.cache.fetch(page_id) catch return false;
            defer page.deinit();
            const bytes = try page.data();
            if (bytes.len < common_len) {
                return false;
            }
            const magic = try readU32(bytes, 0);
            return (magic == state_magic and bytes[4] == @intFromEnum(Role.state) and bytes[5] == version) or
                (magic == page_magic and bytes[5] == version and bytes[4] >= @intFromEnum(Role.mark_bitmap) and
                    bytes[4] <= @intFromEnum(Role.free_bitmap)) or
                (bytes.len >= @sizeOf(u16) and
                    std.mem.readInt(u16, bytes[0..@sizeOf(u16)], .little) == queue_page_kind);
        }

        fn validatePageId(self: *const Self, page_id: PageId) BaseError!void {
            if (page_id >= try self.stateUsize(.snapshot_page_count)) {
                return error.InvalidPageId;
            }
        }

        fn validateMetadata(_: *const Self, bytes: []const u8, role: Role) BaseError!void {
            if (bytes.len < common_len or try readU32(bytes, 0) != page_magic or
                bytes[4] != @intFromEnum(role) or bytes[5] != version)
            {
                return error.InvalidMetadataPage;
            }
        }

        fn nextPageId(_: *const Self, bytes: []const u8) BaseError!?PageId {
            const value = try readU64(bytes, 8);
            if (value == 0) {
                return null;
            }
            return try pageIdFromU64(value);
        }

        fn bitmapBytesPerPage(self: *const Self) usize {
            return self.cache.pageSize() - common_len;
        }

        fn readU32(bytes: []const u8, offset: usize) BaseError!u32 {
            if (offset + 4 > bytes.len) {
                return error.InvalidState;
            }
            return std.mem.readInt(u32, bytes[offset..][0..4], .little);
        }

        fn writeU32(bytes: []u8, offset: usize, value: u32) BaseError!void {
            if (offset + 4 > bytes.len) {
                return error.InvalidState;
            }
            std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
        }

        fn readU64(bytes: []const u8, offset: usize) BaseError!u64 {
            if (offset + 8 > bytes.len) {
                return error.InvalidState;
            }
            return std.mem.readInt(u64, bytes[offset..][0..8], .little);
        }

        fn writeU64(bytes: []u8, offset: usize, value: u64) BaseError!void {
            if (offset + 8 > bytes.len) {
                return error.InvalidState;
            }
            std.mem.writeInt(u64, bytes[offset..][0..8], value, .little);
        }

        fn readPageId(bytes: []const u8, offset: usize) BaseError!PageId {
            return pageIdFromU64(try readU64(bytes, offset));
        }

        fn writePageId(bytes: []u8, offset: usize, page_id: PageId) BaseError!void {
            try writeU64(bytes, offset, page_id);
        }

        fn pageIdFromU64(value: u64) BaseError!PageId {
            return std.math.cast(PageId, value) orelse error.InvalidState;
        }
    };
}
