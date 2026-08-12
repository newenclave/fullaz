const std = @import("std");
const view = @import("view.zig");
const page_chain = @import("../page_chain/page_chain.zig");
const errors = @import("../../core/errors.zig");

pub const Settings = page_chain.Settings;

pub fn Handle(
    comptime PageCacheT: type,
    comptime StorageManagerT: type,
    comptime Endian: std.builtin.Endian,
) type {
    return HandleImpl(
        PageCacheT,
        StorageManagerT,
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
            AdditionalT,
            SubheaderT,
            FsmT,
            Endian,
        );
    }
    return HandleBidirectionalImpl(
        PageCacheT,
        StorageManagerT,
        AdditionalT,
        SubheaderT,
        FsmT,
        Endian,
    );
}

pub fn HandleBidirectionalImpl(
    comptime PageCacheT: type,
    comptime StorageManagerT: type,
    comptime AdditionalT: type,
    comptime SubheaderT: type,
    comptime FsmT: type,
    comptime Endian: std.builtin.Endian,
) type {
    return HandleDirectionalImpl(
        PageCacheT,
        StorageManagerT,
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
    comptime AdditionalT: type,
    comptime SubheaderT: type,
    comptime FsmT: type,
    comptime Endian: std.builtin.Endian,
) type {
    return HandleDirectionalImpl(
        PageCacheT,
        StorageManagerT,
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
    comptime AdditionalT: type,
    comptime SubheaderT: type,
    comptime FsmT: type,
    comptime forward_only: bool,
    comptime Endian: std.builtin.Endian,
) type {
    const FsmError = if (FsmT != void) FsmT.Error else error{};
    const PosType = StorageManagerT.Size;
    _ = PosType;
    const IndexT = u16;
    const BlockDevice = PageCacheT.UnderlyingDevice;
    const BlockIdType = BlockDevice.BlockId;
    const has_tail = @hasDecl(StorageManagerT, "getLast") and @hasDecl(
        StorageManagerT,
        "setLast",
    );

    const ViewType = view.ViewImpl(
        BlockIdType,
        IndexT,
        AdditionalT,
        forward_only,
        Endian,
        false,
    );
    const ViewTypeConst = view.ViewImpl(
        BlockIdType,
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
        StorageManagerT,
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
        fsm: ?*FsmT = null,
        settings: Settings = .{},
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

        pub fn id(self: *const Self) Error!BlockIdType {
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
            FsmError;

        page_id: BlockIdType,
        slot_id: usize,
        page: ?PageChainHandle.Chunk,
        page_chain: *PageChainHandle,
        last_chunk: *?ChunkHandle,
        fsm: ?*FsmT,
        manager: *StorageManagerT,

        pub fn value(self: *const Self) Error![]const u8 {
            if (self.page) |*p| {
                const sd = try SlotsDirConst.init(try p.data());
                return sd.get(self.slot_id);
            }
            return Error.InvalidIterator;
        }

        pub fn clean(self: *Self) Error!bool {
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
                const total = try self.manager.getTotalSize();
                try self.manager.setTotalSize(total - 1);
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

    const BidirectionalIteratorImpl = struct {
        const Self = @This();
        pub const Error = ChunkHandle.Error || PageChainHandle.Error;

        const Cursor = union(enum) {
            before_first,
            on: usize,
            after_last,
        };

        pub const Result = struct {
            value: []const u8,
            page_id: BlockIdType,
            pos: usize,
        };

        page_itr: PageChainHandle.Iterator,
        cursor: Cursor,
        page_chain: *PageChainHandle,
        last_chunk: *?ChunkHandle,
        fsm: ?*FsmT,
        manager: *StorageManagerT,

        fn init(
            page_itr: PageChainHandle.Iterator,
            cursor: Cursor,
            chain_handle: *PageChainHandle,
            last_chunk: *?ChunkHandle,
            fsm: ?*FsmT,
            manager: *StorageManagerT,
        ) Self {
            return .{
                .page_itr = page_itr,
                .cursor = cursor,
                .page_chain = chain_handle,
                .last_chunk = last_chunk,
                .fsm = fsm,
                .manager = manager,
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
            };
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
        pub const Error = ChunkHandle.Error || PageChainHandle.Error;

        const Cursor = union(enum) {
            before_first,
            on: usize,
            after_last,
        };

        pub const Result = struct {
            value: []const u8,
            page_id: BlockIdType,
            pos: usize,
        };

        page_itr: PageChainHandle.Iterator,
        cursor: Cursor,
        page_chain: *PageChainHandle,
        last_chunk: *?ChunkHandle,
        fsm: ?*FsmT,
        manager: *StorageManagerT,

        fn init(
            page_itr: PageChainHandle.Iterator,
            cursor: Cursor,
            chain_handle: *PageChainHandle,
            last_chunk: *?ChunkHandle,
            fsm: ?*FsmT,
            manager: *StorageManagerT,
        ) Self {
            return .{
                .page_itr = page_itr,
                .cursor = cursor,
                .page_chain = chain_handle,
                .last_chunk = last_chunk,
                .fsm = fsm,
                .manager = manager,
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
            const slot_id = switch (self.cursor) {
                .on => |index| index,
                else => return Error.InvalidIterator,
            };
            var page = (try self.page_itr.chunk()) orelse return Error.InvalidIterator;
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
            };
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
        pub const PageId = BlockIdType;
        pub const Index = IndexT;
        pub const View = ViewType;
        pub const Iterator = if (forward_only) ForwardIteratorImpl else BidirectionalIteratorImpl;
        pub const PendingRemoval = PendingRemovalImpl;
        pub const Error = PageChainHandle.Error ||
            PageCacheT.Error ||
            ViewType.Error ||
            StorageManagerT.Error ||
            FsmError;
        pub const ValueIn = []const u8;
        pub const ValueOut = []const u8;

        ctx: Context = .{},
        last_chunk: ?ChunkHandle = null,

        pub fn init(
            page_cache: *PageCacheT,
            storage_manager: *StorageManagerT,
            settings: Settings,
        ) Error!Self {
            return .{
                .ctx = .{
                    .page_chain = try PageChainHandle.init(
                        page_cache,
                        storage_manager,
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
                    .page_chain = try PageChainHandle.init(
                        page_cache,
                        storage_manager,
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

        pub fn insertUnordered(self: *Self, val: ValueIn) Error!void {
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
                        _ = try self.append(val);
                        return;
                    },
                }

                _ = try sd.insert(val);
                const total = try self.ctx.page_chain.manager().getTotalSize();
                try self.ctx.page_chain.managerMut().setTotalSize(total + 1);
                try self.updatePageInFsm(page_id, sd.availableSpace());
            } else {
                _ = try self.append(val);
            }
        }

        pub fn append(self: *Self, val: ValueIn) Error!PageId {
            try self.hydrateLastChunk();
            if (self.last_chunk) |*last_c| {
                const total = try self.ctx.page_chain.manager().getTotalSize();
                var sd = try last_c.slotsDirMut();
                switch (try sd.canInsert(val.len)) {
                    .need_compact => {
                        try self.compactPage(last_c);
                    },
                    .not_enough => {
                        var next = try self.createPage();
                        errdefer next.deinit();

                        const next_id = try next.id();
                        var next_sd = try next.slotsDirMut();
                        _ = try next_sd.insert(val);

                        try self.ctx.page_chain.insertLast(&next.ph);
                        try self.ctx.page_chain.managerMut().setTotalSize(total + 1);

                        last_c.deinit();
                        self.last_chunk = next;

                        return next_id;
                    },
                    .enough => {},
                }

                _ = try sd.insert(val);
                try self.ctx.page_chain.managerMut().setTotalSize(total + 1);
                try self.updatePageInFsm(try last_c.id(), sd.availableSpace());
                return try self.last_chunk.?.id();
            } else {
                var page = try self.createPage();
                errdefer page.deinit();

                const page_id = try page.id();
                var sd = try page.slotsDirMut();
                _ = try sd.insert(val);

                try self.ctx.page_chain.insertFirst(&page.ph);
                try self.ctx.page_chain.managerMut().setTotalSize(1);
                try self.updatePageInFsm(page_id, sd.availableSpace());
                self.last_chunk = page;
                return page_id;
            }
        }

        fn hydrateLastChunk(self: *Self) Error!void {
            if (self.last_chunk != null) {
                return;
            }
            if (comptime has_tail) {
                const last_id = (try self.ctx.page_chain.manager().getLast()) orelse return;
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
            return @intCast(try self.ctx.page_chain.manager().getTotalSize());
        }

        pub fn iterator(self: *Self) Error!?Iterator {
            if (try self.ctx.page_chain.manager().getFirst() == null) return null;
            return Iterator.init(
                try self.ctx.page_chain.iterator(),
                .before_first,
                &self.ctx.page_chain,
                &self.last_chunk,
                self.ctx.fsm,
                self.ctx.page_chain.managerMut(),
            );
        }

        pub fn iteratorFromEnd(self: *Self) Error!?Iterator {
            if (comptime forward_only) {
                @compileError("Forward-only slot chains do not support reverse iteration");
            }
            if (try self.ctx.page_chain.manager().getFirst() == null) {
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
                self.ctx.page_chain.managerMut(),
            );
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
