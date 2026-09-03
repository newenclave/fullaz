const std = @import("std");
const view = @import("view.zig");
const page_chain = @import("../page_chain/page_chain.zig");
const errors = @import("../../core/errors.zig");
const scanner = @import("scanner.zig");
const structural_mutation = @import("../../core/core.zig").structural_mutation;
const StructuralMutationCoordinator = structural_mutation.StructuralMutationCoordinator;
const state_mod = @import("state.zig");
const storage_manager_mod = @import("../../core/storage_manager.zig");
const storage_manager_contract = @import("../../contracts/storage_manager.zig");
const StateAccessor = storage_manager_mod.StateAccessor;

pub const Settings = page_chain.Settings;

pub fn Handle(
    comptime PageCacheT: type,
    comptime StorageManagerT: type,
    comptime SizeT: type,
    comptime TailT: type,
    comptime Endian: std.builtin.Endian,
) type {
    return HandleImpl(
        PageCacheT,
        StorageManagerT,
        SizeT,
        TailT,
        void,
        void,
        void,
        false,
        Endian,
    );
}

pub fn HandleImpl(
    comptime PageCacheT: type,
    comptime StorageManagerT: type,
    comptime SizeT: type,
    comptime TailT: type,
    comptime AdditionalT: type,
    comptime SubheaderT: type,
    comptime FsmT: type,
    comptime forward_only: bool,
    comptime Endian: std.builtin.Endian,
) type {
    if (forward_only) {
        return HandleForwardImpl(
            PageCacheT,
            StorageManagerT,
            SizeT,
            TailT,
            AdditionalT,
            SubheaderT,
            FsmT,
            Endian,
        );
    }
    return HandleBidirectionalImpl(
        PageCacheT,
        StorageManagerT,
        SizeT,
        TailT,
        AdditionalT,
        SubheaderT,
        FsmT,
        Endian,
    );
}

pub fn HandleBidirectionalImpl(
    comptime PageCacheT: type,
    comptime StorageManagerT: type,
    comptime SizeT: type,
    comptime TailT: type,
    comptime AdditionalT: type,
    comptime SubheaderT: type,
    comptime FsmT: type,
    comptime Endian: std.builtin.Endian,
) type {
    return HandleDirectionalImpl(
        PageCacheT,
        StorageManagerT,
        SizeT,
        TailT,
        AdditionalT,
        SubheaderT,
        FsmT,
        false,
        Endian,
    );
}

pub fn HandleForwardImpl(
    comptime PageCacheT: type,
    comptime StorageManagerT: type,
    comptime SizeT: type,
    comptime TailT: type,
    comptime AdditionalT: type,
    comptime SubheaderT: type,
    comptime FsmT: type,
    comptime Endian: std.builtin.Endian,
) type {
    return HandleDirectionalImpl(
        PageCacheT,
        StorageManagerT,
        SizeT,
        TailT,
        AdditionalT,
        SubheaderT,
        FsmT,
        true,
        Endian,
    );
}

fn HandleDirectionalImpl(
    comptime PageCacheT: type,
    comptime StorageManagerT: type,
    comptime SizeT: type,
    comptime TailT: type,
    comptime AdditionalT: type,
    comptime SubheaderT: type,
    comptime FsmT: type,
    comptime forward_only: bool,
    comptime Endian: std.builtin.Endian,
) type {
    const FsmError = if (FsmT != void) FsmT.Error else error{};
    const IndexT = u16;
    const CachePageId = PageCacheT.Pid;
    const State = state_mod.State(CachePageId, SizeT, TailT, Endian);
    const StateView = StateAccessor(StorageManagerT.StateLeaseType, State);
    const PageChainState = page_chain.State(CachePageId, TailT, Endian);
    const PageChainManager = storage_manager_mod.PagedFieldStorageManager(
        StorageManagerT,
        State,
        "page_chain",
    );
    const has_tail = TailT != void;

    comptime {
        storage_manager_contract.assertPagedStorageManager(StorageManagerT, CachePageId);
        if (@FieldType(State, "page_chain") != PageChainState) {
            @compileError("SlotChain state must contain its exact PageChain state");
        }
    }

    const ViewType = view.ViewImpl(
        CachePageId,
        IndexT,
        AdditionalT,
        forward_only,
        Endian,
        false,
    );
    const ViewTypeConst = view.ViewImpl(
        CachePageId,
        IndexT,
        AdditionalT,
        forward_only,
        Endian,
        true,
    );

    const SlotsDir = ViewType.SlotsDir;
    const SlotsDirConst = ViewTypeConst.SlotsDir;

    const ChunkView = ViewType.Chunk;
    const ChunkViewConst = ViewTypeConst.Chunk;

    const PageChainHandle = page_chain.HandleImpl(
        PageCacheT,
        PageChainManager,
        TailT,
        AdditionalT,
        SubheaderT,
        forward_only,
        Endian,
    );

    const SlotsFlags = enum(IndexT) {
        none = 0,
        tombstone = 1 << 0,
    };

    const SlotCleaner = struct {
        const Self = @This();
        fn cb(self: *const Self, slot_id: usize, flags: IndexT, data: []const u8) bool {
            _ = self;
            _ = slot_id;
            _ = data;
            return flags != 0;
        }
    };

    const Context = struct {
        page_chain: PageChainHandle = undefined,
        page_chain_manager: PageChainManager = undefined,
        storage_manager: *StorageManagerT = undefined,
        fsm: ?*FsmT = null,
        settings: Settings = .{},
        coordinator: StructuralMutationCoordinator = .{},
    };

    const ChunkHandle = struct {
        const Self = @This();
        pub const Error = PageCacheT.Error || ViewTypeConst.Error;

        pub const PageChainChunk = PageChainHandle.Chunk;

        ph: PageChainChunk = undefined,

        pub fn deinit(self: *Self) void {
            self.ph.deinit();
        }

        pub fn view(self: *const Self) Error!ChunkViewConst {
            return ChunkViewConst.init(try self.ph.page());
        }

        pub fn viewMut(self: *Self) Error!ChunkView {
            return ChunkView.init(try self.ph.pageMut());
        }

        pub fn slotsDir(self: *const Self) Error!SlotsDirConst {
            const v = try self.view();
            return try v.slotsDir();
        }

        pub fn slotsDirMut(self: *Self) Error!SlotsDir {
            var v = try self.viewMut();
            return try v.slotsDirMut();
        }

        pub fn size(self: *const Self) Error!usize {
            const v = try self.view();
            return (try v.slotsDir()).size();
        }

        pub fn id(self: *const Self) Error!CachePageId {
            return try self.ph.id();
        }

        pub fn setTombstone(self: *Self, index: IndexT) Error!void {
            var sd = try self.slotsDirMut();
            try sd.setFlags(index, @intCast(@intFromEnum(SlotsFlags.tombstone)));
        }

        pub fn isTombstone(self: *const Self, index: IndexT) Error!bool {
            const sd = try self.slotsDir();
            const flags = try sd.getFlags(index);
            return (flags & @intFromEnum(SlotsFlags.tombstone)) != 0;
        }

        pub fn removeTombstones(self: *Self) Error!usize {
            var sd = try self.slotsDirMut();
            const sc = SlotCleaner{};
            return try sd.removeIf(SlotCleaner.cb, &sc);
        }

        pub fn compact(self: *Self, tmp_buf: []u8) Error!void {
            var sd = try self.slotsDirMut();
            sd.compactWithBuffer(tmp_buf) catch {
                try sd.compactInPlace();
            };
        }
    };

    const PendingRemovalImpl = struct {
        const Self = @This();
        pub const Error = ChunkHandle.Error ||
            PageChainHandle.Error ||
            errors.IteratorError ||
            FsmError ||
            structural_mutation.Error;

        page_id: CachePageId,
        slot_id: usize,
        page: ?PageChainHandle.Chunk,
        page_chain: *PageChainHandle,
        last_chunk: *?ChunkHandle,
        fsm: ?*FsmT,
        manager: *StorageManagerT,
        coordinator: *StructuralMutationCoordinator,

        pub fn value(self: *const Self) Error![]const u8 {
            if (self.page) |*p| {
                const sd = try SlotsDirConst.init(try p.data());
                return sd.get(self.slot_id);
            }
            return Error.InvalidIterator;
        }

        pub fn clean(self: *Self) Error!bool {
            var mutation = try self.coordinator.beginStructuralMutation();
            defer mutation.deinit();
            if (self.page) |*p| {
                var sd = try SlotsDir.init(try p.dataMut());
                if (self.slot_id >= sd.size()) {
                    self.deinitPage();
                    return false;
                }
                const flags = try sd.getFlags(self.slot_id);
                if ((flags & @intFromEnum(SlotsFlags.tombstone)) == 0) {
                    self.deinitPage();
                    return false;
                }

                try sd.remove(self.slot_id);
                errdefer self.deinitPage();
                const page_empty = sd.size() == 0;
                if (comptime FsmT != void) {
                    if (self.fsm) |fsm| {
                        if (page_empty) {
                            try fsm.remove(self.page_id);
                        } else {
                            try fsm.update(self.page_id, @intCast(sd.availableSpace()));
                        }
                    }
                }
                var state_lease = try self.manager.state();
                defer state_lease.deinit();
                const state = try StateView.viewMut(&state_lease);
                const total = state.total_size.get();
                if (total == 0) {
                    return Error.BadData;
                }
                state.total_size.set(total - 1);
                state_lease.finish();
                self.deinitPage();
                if (page_empty) {
                    try self.removeEmptyPage();
                }
                return true;
            }
            return false;
        }

        pub fn deinit(self: *Self) void {
            self.deinitPage();
            self.* = undefined;
        }

        fn deinitPage(self: *Self) void {
            if (self.page) |*p| {
                p.deinit();
                self.page = null;
            }
        }

        fn removeEmptyPage(self: *Self) Error!void {
            if (self.last_chunk.*) |*last_chunk| {
                if (try last_chunk.id() == self.page_id) {
                    last_chunk.deinit();
                    self.last_chunk.* = null;
                }
            }

            var itr = try self.page_chain.iterator();
            while (true) {
                const page = (try itr.get()) orelse {
                    itr.deinit();
                    return Error.InvalidId;
                };
                if (page.page_id == self.page_id) {
                    var replacement = try self.page_chain.remove(itr);
                    replacement.deinit();
                    return;
                }
                try itr.next();
            }
        }
    };

    const TombstoneMarker = struct {
        fn forIterator(comptime IteratorT: type) type {
            return struct {
                const Error = IteratorT.Error;
                fn markTombstone(self: *IteratorT) Error!void {
                    const slot_id = switch (self.cursor) {
                        .on => |index| index,
                        else => return Error.InvalidIterator,
                    };
                    var page = (try self.page_itr.cloneChunk()) orelse return Error.InvalidIterator;
                    defer page.deinit();
                    var slots_dir = try SlotsDir.init(try page.dataMut());
                    const flags = try slots_dir.getFlags(slot_id);
                    if ((flags & @intFromEnum(SlotsFlags.tombstone)) == 0) {
                        try slots_dir.setFlags(slot_id, @intCast(@intFromEnum(SlotsFlags.tombstone)));
                    }
                }
            };
        }
    };

    const ValueEditorImpl = struct {
        const EditorSelf = @This();

        pub const Error = PageCacheT.Error ||
            ViewType.Error ||
            structural_mutation.Error ||
            error{InvalidReference};

        layout_lock: ?PageCacheT.Handle.LayoutLock,
        snapshot: ?PageCacheT.Handle,
        position: usize,
        value_len: usize,
        coordinator: *StructuralMutationCoordinator,
        open: bool = true,

        fn init(
            layout_lock: PageCacheT.Handle.LayoutLock,
            snapshot: PageCacheT.Handle,
            position: usize,
            value_len: usize,
            coordinator: *StructuralMutationCoordinator,
        ) EditorSelf {
            return .{
                .layout_lock = layout_lock,
                .snapshot = snapshot,
                .position = position,
                .value_len = value_len,
                .coordinator = coordinator,
            };
        }

        pub fn valueMut(self: *EditorSelf) Error![]u8 {
            try self.ensureOpen();
            if (self.layout_lock) |*layout_lock| {
                var chunk = ChunkView.init(try layout_lock.dataMut());
                var slots_dir = try chunk.slotsDirMut();
                const value = try slots_dir.getMut(self.position);
                if (value.len != self.value_len) {
                    return error.EditorInvalidated;
                }
                return value;
            }
            return error.EditorInvalidated;
        }

        pub fn originalValue(self: *const EditorSelf) Error![]const u8 {
            try self.ensureOpen();
            if (self.snapshot) |*snapshot| {
                return (try snapshot.data())[0..self.value_len];
            }
            return error.EditorInvalidated;
        }

        pub fn finish(self: *EditorSelf) Error!void {
            try self.ensureOpen();
            self.close();
        }

        pub fn deinit(self: *EditorSelf) void {
            if (!self.open) {
                return;
            }
            self.restore() catch @panic("slot chain value editor rollback failed");
            self.close();
        }

        fn ensureOpen(self: *const EditorSelf) Error!void {
            if (!self.open) {
                return error.EditorInvalidated;
            }
        }

        fn restore(self: *EditorSelf) Error!void {
            if (self.layout_lock) |*layout_lock| {
                if (self.snapshot) |*snapshot| {
                    const snapshot_bytes = try snapshot.data();
                    var chunk = ChunkView.init(try layout_lock.dataMut());
                    var slots_dir = try chunk.slotsDirMut();
                    const value = try slots_dir.getMut(self.position);
                    if (value.len != self.value_len) {
                        return error.EditorInvalidated;
                    }
                    @memcpy(value, snapshot_bytes[0..self.value_len]);
                    return;
                }
            }
            return error.EditorInvalidated;
        }

        fn close(self: *EditorSelf) void {
            if (self.layout_lock) |*layout_lock| {
                layout_lock.deinit();
                self.layout_lock = null;
            }
            if (self.snapshot) |*snapshot| {
                snapshot.deinit();
                self.snapshot = null;
            }
            self.coordinator.finishValueEditor();
            self.open = false;
        }
    };

    const ValueEditorOpener = struct {
        fn open(
            coordinator: *StructuralMutationCoordinator,
            page: *ChunkHandle,
            position: usize,
            cache: *PageCacheT,
        ) ValueEditorImpl.Error!ValueEditorImpl {
            try coordinator.beginValueEditor();
            errdefer coordinator.finishValueEditor();

            const slots_dir = try page.slotsDir();
            if (position >= slots_dir.size() or try page.isTombstone(@intCast(position))) {
                return error.InvalidReference;
            }
            const value = try slots_dir.get(position);

            var snapshot = try cache.getTemporaryPage();
            errdefer snapshot.deinit();
            const snapshot_bytes = try snapshot.dataMut();
            @memcpy(snapshot_bytes[0..value.len], value);

            var layout_lock = try page.ph.ph.lockLayout();
            errdefer layout_lock.deinit();
            return ValueEditorImpl.init(
                layout_lock,
                snapshot,
                position,
                value.len,
                coordinator,
            );
        }
    };

    const BidirectionalIteratorImpl = struct {
        const Self = @This();
        pub const Error = ChunkHandle.Error ||
            PageChainHandle.Error ||
            structural_mutation.Error ||
            error{InvalidReference};

        const Cursor = union(enum) {
            before_first,
            on: usize,
            after_last,
        };

        pub const Result = struct {
            value: []const u8,
            page_id: CachePageId,
            pos: usize,
        };

        page_itr: PageChainHandle.Iterator,
        cursor: Cursor,
        page_chain: *PageChainHandle,
        last_chunk: *?ChunkHandle,
        fsm: ?*FsmT,
        manager: *StorageManagerT,
        coordinator: *StructuralMutationCoordinator,
        structural_generation: u64,

        fn init(
            page_itr: PageChainHandle.Iterator,
            cursor: Cursor,
            chain_handle: *PageChainHandle,
            last_chunk: *?ChunkHandle,
            fsm: ?*FsmT,
            manager: *StorageManagerT,
            coordinator: *StructuralMutationCoordinator,
        ) Self {
            return .{
                .page_itr = page_itr,
                .cursor = cursor,
                .page_chain = chain_handle,
                .last_chunk = last_chunk,
                .fsm = fsm,
                .manager = manager,
                .coordinator = coordinator,
                .structural_generation = coordinator.generation(),
            };
        }

        pub fn get(self: *const Self) Error!?Result {
            const pos = switch (self.cursor) {
                .on => |index| index,
                else => return null,
            };
            const page = (try self.page_itr.get()) orelse return null;
            const sd = try SlotsDirConst.init(page.value);
            if (pos >= sd.size()) {
                return null;
            }
            return .{
                .value = try sd.get(pos),
                .page_id = page.page_id,
                .pos = pos,
            };
        }

        pub fn next(self: *Self) Error!?Result {
            const start = switch (self.cursor) {
                .before_first => 0,
                .on => |pos| pos + 1,
                .after_last => return null,
            };
            if (!try self.findNext(start)) {
                self.cursor = .after_last;
                return null;
            }
            return self.get();
        }

        pub fn prev(self: *Self) Error!?Result {
            const start = switch (self.cursor) {
                .before_first => return null,
                .on => |pos| pos,
                .after_last => blk: {
                    try self.page_itr.prev();
                    const page = (try self.page_itr.get()) orelse return null;
                    const sd = try SlotsDirConst.init(page.value);
                    break :blk sd.size();
                },
            };
            if (!try self.findPrev(start)) {
                self.cursor = .before_first;
                return null;
            }
            return self.get();
        }

        pub fn deinit(self: *Self) void {
            self.page_itr.deinit();
        }

        pub fn markForRemoval(self: *Self) Error!PendingRemovalImpl {
            var mutation = try self.coordinator.beginStructuralMutation();
            defer mutation.deinit();
            const slot_id = switch (self.cursor) {
                .on => |index| index,
                else => return Error.InvalidIterator,
            };
            var page = (try self.page_itr.cloneChunk()) orelse return Error.InvalidIterator;
            errdefer page.deinit();

            var sd = try SlotsDir.init(try page.dataMut());
            try sd.setFlags(slot_id, @intCast(@intFromEnum(SlotsFlags.tombstone)));
            return .{
                .page_id = try page.id(),
                .slot_id = slot_id,
                .page = page,
                .page_chain = self.page_chain,
                .last_chunk = self.last_chunk,
                .fsm = self.fsm,
                .manager = self.manager,
                .coordinator = self.coordinator,
            };
        }

        pub fn markTombstone(self: *Self) Error!void {
            var mutation = try self.coordinator.beginStructuralMutation();
            defer mutation.deinit();
            return TombstoneMarker.forIterator(Self).markTombstone(self);
        }

        pub fn editValue(self: *Self) Error!?ValueEditorImpl {
            try self.coordinator.checkGeneration(self.structural_generation);
            const position = switch (self.cursor) {
                .on => |value| value,
                else => return null,
            };
            var page = ChunkHandle{
                .ph = (try self.page_itr.cloneChunk()) orelse return null,
            };
            defer page.deinit();
            return try ValueEditorOpener.open(
                self.coordinator,
                &page,
                position,
                self.page_chain.cacheMut(),
            );
        }

        fn findNext(self: *Self, start: usize) Error!bool {
            var index = start;
            while (true) {
                const page = (try self.page_itr.get()) orelse return false;
                const sd = try SlotsDirConst.init(page.value);
                while (index < sd.size()) : (index += 1) {
                    const flags = try sd.getFlags(index);
                    if ((flags & @intFromEnum(SlotsFlags.tombstone)) == 0) {
                        self.cursor = .{
                            .on = index,
                        };
                        return true;
                    }
                }
                try self.page_itr.next();
                index = 0;
            }
        }

        fn findPrev(self: *Self, start: usize) Error!bool {
            var index = start;
            while (true) {
                const page = (try self.page_itr.get()) orelse return false;
                const sd = try SlotsDirConst.init(page.value);
                while (index > 0) {
                    index -= 1;
                    const flags = try sd.getFlags(index);
                    if ((flags & @intFromEnum(SlotsFlags.tombstone)) == 0) {
                        self.cursor = .{
                            .on = index,
                        };
                        return true;
                    }
                }
                try self.page_itr.prev();
                if (try self.page_itr.get()) |prev_page| {
                    const prev_sd = try SlotsDirConst.init(prev_page.value);
                    index = prev_sd.size();
                } else {
                    return false;
                }
            }
        }
    };

    const ForwardIteratorImpl = struct {
        const Self = @This();
        pub const Error = ChunkHandle.Error ||
            PageChainHandle.Error ||
            structural_mutation.Error ||
            error{InvalidReference};

        const Cursor = union(enum) {
            before_first,
            on: usize,
            after_last,
        };

        pub const Result = struct {
            value: []const u8,
            page_id: CachePageId,
            pos: usize,
        };

        page_itr: PageChainHandle.Iterator,
        cursor: Cursor,
        page_chain: *PageChainHandle,
        last_chunk: *?ChunkHandle,
        fsm: ?*FsmT,
        manager: *StorageManagerT,
        coordinator: *StructuralMutationCoordinator,
        structural_generation: u64,

        fn init(
            page_itr: PageChainHandle.Iterator,
            cursor: Cursor,
            chain_handle: *PageChainHandle,
            last_chunk: *?ChunkHandle,
            fsm: ?*FsmT,
            manager: *StorageManagerT,
            coordinator: *StructuralMutationCoordinator,
        ) Self {
            return .{
                .page_itr = page_itr,
                .cursor = cursor,
                .page_chain = chain_handle,
                .last_chunk = last_chunk,
                .fsm = fsm,
                .manager = manager,
                .coordinator = coordinator,
                .structural_generation = coordinator.generation(),
            };
        }

        pub fn get(self: *const Self) Error!?Result {
            const pos = switch (self.cursor) {
                .on => |index| index,
                else => return null,
            };
            const page = (try self.page_itr.get()) orelse return null;
            const sd = try SlotsDirConst.init(page.value);
            if (pos >= sd.size()) {
                return null;
            }
            return .{
                .value = try sd.get(pos),
                .page_id = page.page_id,
                .pos = pos,
            };
        }

        pub fn next(self: *Self) Error!?Result {
            const start = switch (self.cursor) {
                .before_first => 0,
                .on => |pos| pos + 1,
                .after_last => return null,
            };
            if (!try self.findNext(start)) {
                self.cursor = .after_last;
                return null;
            }
            return self.get();
        }

        pub fn deinit(self: *Self) void {
            self.page_itr.deinit();
        }

        pub fn markForRemoval(self: *Self) Error!PendingRemovalImpl {
            var mutation = try self.coordinator.beginStructuralMutation();
            defer mutation.deinit();
            const slot_id = switch (self.cursor) {
                .on => |index| index,
                else => return Error.InvalidIterator,
            };
            var page = (try self.page_itr.cloneChunk()) orelse return Error.InvalidIterator;
            errdefer page.deinit();

            var sd = try SlotsDir.init(try page.dataMut());
            try sd.setFlags(slot_id, @intCast(@intFromEnum(SlotsFlags.tombstone)));
            return .{
                .page_id = try page.id(),
                .slot_id = slot_id,
                .page = page,
                .page_chain = self.page_chain,
                .last_chunk = self.last_chunk,
                .fsm = self.fsm,
                .manager = self.manager,
                .coordinator = self.coordinator,
            };
        }

        pub fn markTombstone(self: *Self) Error!void {
            var mutation = try self.coordinator.beginStructuralMutation();
            defer mutation.deinit();
            return TombstoneMarker.forIterator(Self).markTombstone(self);
        }

        pub fn editValue(self: *Self) Error!?ValueEditorImpl {
            try self.coordinator.checkGeneration(self.structural_generation);
            const position = switch (self.cursor) {
                .on => |value| value,
                else => return null,
            };
            var page = ChunkHandle{
                .ph = (try self.page_itr.cloneChunk()) orelse return null,
            };
            defer page.deinit();
            return try ValueEditorOpener.open(
                self.coordinator,
                &page,
                position,
                self.page_chain.cacheMut(),
            );
        }

        fn findNext(self: *Self, start: usize) Error!bool {
            var index = start;
            while (true) {
                const page = (try self.page_itr.get()) orelse return false;
                const sd = try SlotsDirConst.init(page.value);
                while (index < sd.size()) : (index += 1) {
                    const flags = try sd.getFlags(index);
                    if ((flags & @intFromEnum(SlotsFlags.tombstone)) == 0) {
                        self.cursor = .{ .on = index };
                        return true;
                    }
                }
                try self.page_itr.next();
                index = 0;
            }
        }
    };

    return struct {
        const Self = @This();
        pub const PageId = CachePageId;
        pub const Index = IndexT;
        pub const Size = SizeT;
        pub const StateType = State;
        pub const View = ViewType;
        pub const Iterator = if (forward_only) ForwardIteratorImpl else BidirectionalIteratorImpl;
        pub const PendingRemoval = PendingRemovalImpl;
        pub const ValueEditor = ValueEditorImpl;
        pub const Error = PageChainHandle.Error ||
            PageCacheT.Error ||
            ViewType.Error ||
            StorageManagerT.Error ||
            StateView.Error ||
            FsmError ||
            structural_mutation.Error ||
            error{InvalidReference};
        pub const ReferenceError = Error;
        pub const ValueIn = []const u8;
        pub const ValueOut = []const u8;
        pub const SlotRef = struct {
            page_id: PageId,
            slot_id: Index,
        };

        pub const Record = struct {
            const RecordSelf = @This();

            page: ?ChunkHandle,
            slot_id: Index,

            pub fn deinit(self: *RecordSelf) void {
                if (self.page) |*page| {
                    page.deinit();
                }
                self.* = undefined;
            }

            pub fn value(self: *const RecordSelf) ReferenceError![]const u8 {
                const page_handle = if (self.page) |*handle| handle else return error.InvalidReference;
                const slots_dir = try page_handle.slotsDir();
                const slot_index: usize = self.slot_id;
                if (slot_index >= slots_dir.size() or
                    try page_handle.isTombstone(self.slot_id))
                {
                    return error.InvalidReference;
                }
                return try slots_dir.get(slot_index);
            }
        };

        ctx: Context = .{},
        last_chunk: ?ChunkHandle = null,

        pub fn init(
            page_cache: *PageCacheT,
            storage_manager: *StorageManagerT,
            settings: Settings,
        ) Error!Self {
            return .{
                .ctx = .{
                    .page_chain_manager = PageChainManager.init(storage_manager),
                    .storage_manager = storage_manager,
                    .page_chain = try PageChainHandle.initUnbound(
                        page_cache,
                        .{
                            .chunk_page_kind = settings.chunk_page_kind,
                        },
                    ),
                    .settings = settings,
                },
            };
        }

        pub fn initWithFsm(
            page_cache: *PageCacheT,
            storage_manager: *StorageManagerT,
            fsm: *FsmT,
            settings: Settings,
        ) Error!Self {
            return .{
                .ctx = .{
                    .page_chain_manager = PageChainManager.init(storage_manager),
                    .storage_manager = storage_manager,
                    .page_chain = try PageChainHandle.initUnbound(
                        page_cache,
                        .{
                            .chunk_page_kind = settings.chunk_page_kind,
                        },
                    ),
                    .fsm = fsm,
                    .settings = settings,
                },
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.last_chunk) |*last_c| {
                last_c.deinit();
            }
            self.ctx.page_chain.deinit();
        }

        pub fn scanChunkRefs(
            self: *const Self,
            page_id: PageId,
            page: []const u8,
            visitor: anytype,
        ) !void {
            return scanner.scanRefs(
                PageId,
                IndexT,
                forward_only,
                Endian,
                page_id,
                page,
                self.ctx.settings.chunk_page_kind,
                visitor,
            );
        }

        fn compactPage(self: *const Self, page: *ChunkHandle) Error!void {
            var sv = try page.slotsDirMut();
            var tmp = self.ctx.page_chain.page_cache.getTemporaryPage() catch {
                try sv.compactInPlace();
                return;
            };
            defer tmp.deinit();
            sv.compactWithBuffer(try tmp.dataMut()) catch {
                try sv.compactInPlace();
            };
        }

        fn preparePageChain(self: *Self) void {
            self.ctx.page_chain.rebindStorageManager(&self.ctx.page_chain_manager);
        }

        fn firstId(self: *const Self) Error!?PageId {
            var lease = try self.ctx.storage_manager.state();
            defer lease.deinit();
            const first = (try StateView.view(&lease)).page_chain.first.get();
            return if (first == std.math.maxInt(PageId)) null else first;
        }

        fn lastId(self: *const Self) Error!?PageId {
            if (comptime !has_tail) {
                @compileError("Root-only SlotChain state does not store a tail");
            }
            var lease = try self.ctx.storage_manager.state();
            defer lease.deinit();
            const last = (try StateView.view(&lease)).page_chain.last.get();
            return if (last == std.math.maxInt(PageId)) null else last;
        }

        fn totalSize(self: *const Self) Error!Size {
            var lease = try self.ctx.storage_manager.state();
            defer lease.deinit();
            return (try StateView.view(&lease)).total_size.get();
        }

        fn setTotalSize(self: *Self, total_size: Size) Error!void {
            var lease = try self.ctx.storage_manager.state();
            defer lease.deinit();
            (try StateView.viewMut(&lease)).total_size.set(total_size);
            lease.finish();
        }

        fn incrementTotalSize(self: *Self) Error!void {
            const total = try self.totalSize();
            try self.setTotalSize(std.math.add(Size, total, 1) catch return Error.BadData);
        }

        fn decrementTotalSize(self: *Self, removed_slots: usize) Error!void {
            const removed = std.math.cast(Size, removed_slots) orelse return Error.BadData;
            const total = try self.totalSize();
            if (removed > total) {
                return Error.BadData;
            }
            try self.setTotalSize(total - removed);
        }

        fn finishPageRemoval(
            self: *Self,
            page_id: PageId,
            removed_slots: usize,
            remaining_slots: usize,
            free_space: usize,
        ) Error!void {
            if (removed_slots == 0) {
                return;
            }

            try self.decrementTotalSize(removed_slots);

            if (comptime FsmT != void) {
                if (self.ctx.fsm) |fsm| {
                    if (remaining_slots == 0) {
                        try fsm.remove(page_id);
                    } else {
                        try fsm.update(page_id, @intCast(free_space));
                    }
                }
            }

            if (remaining_slots == 0) {
                if (self.last_chunk) |*last_chunk| {
                    if (try last_chunk.id() == page_id) {
                        last_chunk.deinit();
                        self.last_chunk = null;
                    }
                }
                try self.removePage(page_id);
            }
        }

        fn removePage(self: *Self, page_id: PageId) Error!void {
            self.preparePageChain();
            var chain_iterator = try self.ctx.page_chain.iterator();
            while (true) {
                const page = (try chain_iterator.get()) orelse {
                    chain_iterator.deinit();
                    return Error.InvalidId;
                };
                if (page.page_id == page_id) {
                    var replacement = try self.ctx.page_chain.remove(chain_iterator);
                    replacement.deinit();
                    return;
                }
                try chain_iterator.next();
            }
        }

        pub fn insertUnordered(self: *Self, val: ValueIn) Error!void {
            var mutation = try self.ctx.coordinator.beginStructuralMutation();
            defer mutation.deinit();
            if (try self.findFreeSlot(val.len)) |page_id| {
                var page = try self.loadPage(page_id);
                defer page.deinit();
                var sd = try page.slotsDirMut();

                switch (try sd.canInsert(val.len)) {
                    .enough => {},
                    .need_compact => {
                        try self.compactPage(&page);
                        sd = try page.slotsDirMut();
                    },
                    .not_enough => {
                        try self.updatePageInFsm(page_id, sd.availableSpace());
                        _ = try self.appendRefInner(val);
                        return;
                    },
                }

                _ = try sd.insert(val);
                try self.incrementTotalSize();
                try self.updatePageInFsm(page_id, sd.availableSpace());
            } else {
                _ = try self.appendRefInner(val);
            }
        }

        pub fn append(self: *Self, val: ValueIn) Error!PageId {
            return (try self.appendRef(val)).page_id;
        }

        /// Appends an entry and returns its stable directory position. Callers
        /// that retain this reference must not use physical slot removal APIs.
        pub fn appendRef(self: *Self, val: ValueIn) Error!SlotRef {
            var mutation = try self.ctx.coordinator.beginStructuralMutation();
            defer mutation.deinit();
            return self.appendRefInner(val);
        }

        fn appendRefInner(self: *Self, val: ValueIn) Error!SlotRef {
            self.preparePageChain();
            try self.hydrateLastChunk();
            if (self.last_chunk) |*last_c| {
                var sd = try last_c.slotsDirMut();
                switch (try sd.canInsert(val.len)) {
                    .need_compact => {
                        try self.compactPage(last_c);
                    },
                    .not_enough => {
                        var next = try self.createPageInner();
                        errdefer next.deinit();

                        const next_id = try next.id();
                        var next_sd = try next.slotsDirMut();
                        const slot_id: Index = @intCast(try next_sd.insert(val));

                        try self.ctx.page_chain.insertLast(&next.ph);
                        try self.incrementTotalSize();

                        last_c.deinit();
                        self.last_chunk = next;

                        return .{ .page_id = next_id, .slot_id = slot_id };
                    },
                    .enough => {},
                }

                const slot_id: Index = @intCast(try sd.insert(val));
                try self.incrementTotalSize();
                try self.updatePageInFsm(try last_c.id(), sd.availableSpace());
                return .{
                    .page_id = try self.last_chunk.?.id(),
                    .slot_id = slot_id,
                };
            } else {
                var page = try self.createPageInner();
                errdefer page.deinit();

                const page_id = try page.id();
                var sd = try page.slotsDirMut();
                const slot_id: Index = @intCast(try sd.insert(val));

                try self.ctx.page_chain.insertFirst(&page.ph);
                try self.setTotalSize(1);
                try self.updatePageInFsm(page_id, sd.availableSpace());
                self.last_chunk = page;
                return .{ .page_id = page_id, .slot_id = slot_id };
            }
        }

        /// Loads one live entry by a SlotRef and keeps its page pinned until
        /// Record.deinit(). The reference does not survive physical removal.
        pub fn loadRef(self: *const Self, ref: SlotRef) ReferenceError!Record {
            var page = try self.loadPage(ref.page_id);
            errdefer page.deinit();
            const slots_dir = try page.slotsDir();
            const slot_index: usize = ref.slot_id;
            if (slot_index >= slots_dir.size() or try page.isTombstone(ref.slot_id)) {
                return error.InvalidReference;
            }
            return .{
                .page = page,
                .slot_id = ref.slot_id,
            };
        }

        /// Opens an exact-length mutable editor for the live slot referenced by `ref`.
        pub fn openValueEditor(self: *Self, ref: SlotRef) Error!ValueEditor {
            var page = try self.loadPage(ref.page_id);
            defer page.deinit();
            return try ValueEditorOpener.open(
                &self.ctx.coordinator,
                &page,
                ref.slot_id,
                self.ctx.page_chain.cacheMut(),
            );
        }

        fn hydrateLastChunk(self: *Self) Error!void {
            if (self.last_chunk != null) {
                return;
            }
            if (comptime has_tail) {
                const last_id = (try self.lastId()) orelse return;
                self.last_chunk = try self.loadPage(last_id);
                return;
            }

            var page_itr = try self.ctx.page_chain.iterator();
            defer page_itr.deinit();

            while (true) {
                const page = (try page_itr.get()) orelse return;
                const chunk = try self.loadPage(page.page_id);
                if (self.last_chunk) |*last_chunk| {
                    last_chunk.deinit();
                }
                self.last_chunk = chunk;

                try page_itr.next();
            }
        }

        pub fn size(self: *const Self) Error!usize {
            return @intCast(try self.totalSize());
        }

        /// Releases the optional append cache before external page reclamation.
        pub fn releaseCachedTail(self: *Self) void {
            if (self.last_chunk) |*chunk| {
                chunk.deinit();
            }
            self.last_chunk = null;
        }

        pub fn iterator(self: *Self) Error!?Iterator {
            self.preparePageChain();
            if (try self.firstId() == null) {
                return null;
            }
            return Iterator.init(
                try self.ctx.page_chain.iterator(),
                .before_first,
                &self.ctx.page_chain,
                &self.last_chunk,
                self.ctx.fsm,
                self.ctx.storage_manager,
                &self.ctx.coordinator,
            );
        }

        pub fn iteratorFromEnd(self: *Self) Error!?Iterator {
            if (comptime forward_only) {
                @compileError("Forward-only slot chains do not support reverse iteration");
            }
            self.preparePageChain();
            if (try self.firstId() == null) {
                return null;
            }
            var page_itr = try self.ctx.page_chain.iteratorFromEnd();
            try page_itr.next();
            return Iterator.init(
                page_itr,
                .after_last,
                &self.ctx.page_chain,
                &self.last_chunk,
                self.ctx.fsm,
                self.ctx.storage_manager,
                &self.ctx.coordinator,
            );
        }

        /// Marks live slots selected by `predicate` without changing page size or FSM state.
        /// `value` is borrowed for the duration of the predicate call.
        pub fn markTombstonesIf(self: *Self, context: anytype, comptime predicate: anytype) Error!usize {
            var mutation = try self.ctx.coordinator.beginStructuralMutation();
            defer mutation.deinit();
            var chain_iterator = (try self.iterator()) orelse return 0;
            defer chain_iterator.deinit();

            var marked: usize = 0;
            while (try chain_iterator.next()) |result| {
                if (try predicate(context, result.page_id, result.pos, result.value)) {
                    try TombstoneMarker.forIterator(Iterator).markTombstone(&chain_iterator);
                    marked += 1;
                }
            }
            return marked;
        }

        /// Physically removes all tombstoned slots and returns their count.
        pub fn removeTombstones(self: *Self) Error!usize {
            var mutation = try self.ctx.coordinator.beginStructuralMutation();
            defer mutation.deinit();
            self.preparePageChain();
            var chain_iterator = try self.ctx.page_chain.iterator();
            defer chain_iterator.deinit();

            var removed_total: usize = 0;
            while (try chain_iterator.get()) |page_result| {
                var page = try self.loadPage(page_result.page_id);
                const removed_slots = try page.removeTombstones();
                const remaining_slots = try page.size();
                const free_space = (try page.slotsDir()).availableSpace();
                page.deinit();

                try self.finishPageRemoval(
                    page_result.page_id,
                    removed_slots,
                    remaining_slots,
                    free_space,
                );
                removed_total += removed_slots;
                try chain_iterator.next();
            }
            return removed_total;
        }

        /// Physically removes tombstoned slots from one page and returns their count.
        pub fn removePageTombstones(self: *Self, page_id: PageId) Error!usize {
            var mutation = try self.ctx.coordinator.beginStructuralMutation();
            defer mutation.deinit();
            var page = try self.loadPage(page_id);
            const removed_slots = try page.removeTombstones();
            const remaining_slots = try page.size();
            const free_space = (try page.slotsDir()).availableSpace();
            page.deinit();

            try self.finishPageRemoval(page_id, removed_slots, remaining_slots, free_space);
            return removed_slots;
        }

        /// Physically removes live slots selected by `predicate` and returns their count.
        /// `value` is borrowed for the duration of the predicate call.
        pub fn removeIf(self: *Self, context: anytype, comptime predicate: anytype) Error!usize {
            var mutation = try self.ctx.coordinator.beginStructuralMutation();
            defer mutation.deinit();
            self.preparePageChain();
            const PredicateContext = struct {
                const CallbackContext = @TypeOf(context);

                context: CallbackContext,
                page_id: PageId,
                callback_error: ?Error = null,

                fn call(callback_state: *@This(), slot_index: usize, flags: IndexT, value: []const u8) bool {
                    if ((flags & @intFromEnum(SlotsFlags.tombstone)) != 0) {
                        return false;
                    }
                    return predicate(callback_state.context, callback_state.page_id, slot_index, value) catch |err| {
                        callback_state.callback_error = err;
                        return false;
                    };
                }
            };

            var chain_iterator = try self.ctx.page_chain.iterator();
            defer chain_iterator.deinit();

            var removed_total: usize = 0;
            while (try chain_iterator.get()) |page_result| {
                var page = try self.loadPage(page_result.page_id);
                var slots_dir = try page.slotsDirMut();
                var predicate_context = PredicateContext{
                    .context = context,
                    .page_id = page_result.page_id,
                };
                const removed_slots = try slots_dir.removeIf(PredicateContext.call, &predicate_context);
                const remaining_slots = try page.size();
                const free_space = (try page.slotsDir()).availableSpace();
                page.deinit();

                try self.finishPageRemoval(
                    page_result.page_id,
                    removed_slots,
                    remaining_slots,
                    free_space,
                );
                removed_total += removed_slots;
                if (predicate_context.callback_error) |err| {
                    return err;
                }
                try chain_iterator.next();
            }
            return removed_total;
        }

        /// Rebinds a pending removal to this handle's chain state and manager.
        pub fn rebindPendingRemoval(self: *Self, pending: *PendingRemoval) void {
            self.preparePageChain();
            pending.page_chain = &self.ctx.page_chain;
            pending.last_chunk = &self.last_chunk;
            pending.manager = self.ctx.storage_manager;
            pending.coordinator = &self.ctx.coordinator;
        }

        pub fn insertPageToFsm(self: *Self, page_id: PageId, free_size: usize) Error!void {
            if (comptime FsmT == void) {
                return;
            }
            const fsm = self.ctx.fsm orelse return;
            try fsm.add(page_id, @intCast(free_size));
        }

        pub fn findFreeSlot(self: *Self, required_size: usize) Error!?PageId {
            if (comptime FsmT == void) {
                return null;
            }
            const full_slot_size = SlotsDirConst.fullSlotSize(required_size);
            const fsm = self.ctx.fsm orelse return null;
            return fsm.find(@intCast(full_slot_size));
        }

        pub fn loadPage(self: *const Self, pid: PageId) Error!ChunkHandle {
            return .{
                .ph = try self.ctx.page_chain.loadChunk(pid),
            };
        }

        pub fn createPage(self: *Self) Error!ChunkHandle {
            var mutation = try self.ctx.coordinator.beginStructuralMutation();
            defer mutation.deinit();
            return self.createPageInner();
        }

        fn createPageInner(self: *Self) Error!ChunkHandle {
            var ch: ChunkHandle = .{
                .ph = try self.ctx.page_chain.createChunk(),
            };
            errdefer ch.deinit();
            var sd = try ch.slotsDirMut();
            sd.formatHeader();
            try self.insertPageToFsm(try ch.id(), sd.availableSpace());
            return ch;
        }

        fn updatePageInFsm(self: *Self, page_id: PageId, free_size: usize) Error!void {
            if (comptime FsmT == void) {
                return;
            }
            const fsm = self.ctx.fsm orelse return;
            try fsm.update(page_id, @intCast(free_size));
        }
    };
}
