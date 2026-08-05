const std = @import("std");
const view = @import("view.zig");

pub const Settings = struct {
    chunk_page_kind: u16 = 0x41,
};

pub fn Handle(
    comptime PageCacheType: type,
    comptime StorageManager: type,
    comptime Endian: std.builtin.Endian,
) type {
    const PosType = StorageManager.Size;
    _ = PosType;
    const IndexT = u16;
    const BlockDevice = PageCacheType.UnderlyingDevice;
    const PageHandle = PageCacheType.Handle;
    const BlockIdType = BlockDevice.BlockId;

    const ViewType = view.View(BlockIdType, IndexT, Endian, false);
    const ViewTypeConst = view.View(BlockIdType, IndexT, Endian, true);

    const SlotsDir = ViewType.SlotsDir;
    const SlotsDirConst = ViewTypeConst.SlotsDir;

    const ChunkView = ViewType.Chunk;
    const ChunkViewConst = ViewTypeConst.Chunk;

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

    const ChunkHandle = struct {
        const Self = @This();
        pub const Error = PageCacheType.Error || ViewTypeConst.Error;
        ph: PageHandle,
        fn init(ph: PageHandle) Self {
            return .{ .ph = ph };
        }

        pub fn deinit(self: *Self) void {
            self.ph.deinit();
        }

        pub fn view(self: *const Self) Error!ChunkViewConst {
            return ChunkViewConst.init(try self.ph.getData());
        }

        pub fn viewMut(self: *Self) Error!ChunkView {
            return ChunkView.init(try self.ph.getDataMut());
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
            return try self.ph.pid();
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

    const IteratorImpl = struct {
        const Self = @This();
        pub const Error = ChunkHandle.Error;

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

        fn init(page_cache: *PageCacheType, page_id: BlockIdType, cursor: Cursor) Error!Self {
            return .{
                .page_cache = page_cache,
                .page = ChunkHandle.init(try page_cache.fetch(page_id)),
                .cursor = cursor,
            };
        }

        pub fn get(self: *const Self) Error!?Result {
            const page = self.page orelse return null;
            const pos = switch (self.cursor) {
                .on => |index| index,
                else => return null,
            };
            const sd = try page.slotsDir();
            if (pos >= sd.size()) {
                return null;
            }
            return .{
                .value = try sd.get(pos),
                .page_id = try page.id(),
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
                    const page = self.page orelse return null;
                    break :blk try page.size();
                },
            };
            if (!try self.findPrev(start)) {
                self.cursor = .before_first;
                return null;
            }
            return self.get();
        }

        pub fn deinit(self: *Self) void {
            if (self.page) |*page| {
                page.deinit();
            }
            self.page = null;
        }

        fn findNext(self: *Self, start: usize) Error!bool {
            var index = start;
            while (true) {
                const page = self.page orelse return false;
                const sd = try page.slotsDir();
                while (index < sd.size()) : (index += 1) {
                    const flags = try sd.getFlags(index);
                    if ((flags & @intFromEnum(SlotsFlags.tombstone)) == 0) {
                        self.cursor = .{
                            .on = index,
                        };
                        return true;
                    }
                }
                if (!try self.moveNextPage()) {
                    return false;
                }
                index = 0;
            }
        }

        fn findPrev(self: *Self, start: usize) Error!bool {
            var index = start;
            while (true) {
                const page = self.page orelse return false;
                const sd = try page.slotsDir();
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
                if (!try self.movePrevPage()) {
                    return false;
                }
                const prev_page = self.page orelse return false;
                index = try prev_page.size();
            }
        }

        fn moveNextPage(self: *Self) Error!bool {
            const page = self.page orelse return false;
            const next_id = (try page.view()).getNext() orelse return false;
            var next_page = ChunkHandle.init(try self.page_cache.fetch(next_id));
            errdefer next_page.deinit();
            if (self.page) |*current| {
                current.deinit();
            }
            self.page = next_page;
            return true;
        }

        fn movePrevPage(self: *Self) Error!bool {
            const page = self.page orelse return false;
            const prev_id = (try page.view()).getPrev() orelse return false;
            var prev_page = ChunkHandle.init(try self.page_cache.fetch(prev_id));
            errdefer prev_page.deinit();
            if (self.page) |*current| {
                current.deinit();
            }
            self.page = prev_page;
            return true;
        }

        page_cache: *PageCacheType,
        page: ?ChunkHandle,
        cursor: Cursor,
    };

    return struct {
        const Self = @This();
        pub const PageId = BlockIdType;
        pub const Index = IndexT;
        pub const View = ViewType;
        pub const Iterator = IteratorImpl;
        pub const Error = PageCacheType.Error ||
            ViewType.Error ||
            StorageManager.Error;
        pub const ValueIn = []const u8;
        pub const ValueOut = []const u8;

        page_cache: *PageCacheType,
        mgr: *StorageManager,
        settings: Settings = .{},
        last_chunk: ?ChunkHandle = null,

        pub fn init(
            page_cache: *PageCacheType,
            storage_manager: *StorageManager,
            settings: Settings,
        ) Error!Self {
            return .{
                .page_cache = page_cache,
                .mgr = storage_manager,
                .settings = settings,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.last_chunk) |*last_c| {
                last_c.deinit();
            }
        }

        fn compactPage(self: *const Self, page: *ChunkHandle) Error!void {
            var sv = try page.slotsDirMut();
            var tmp = self.page_cache.getTemporaryPage() catch {
                try sv.compactInPlace();
                return;
            };
            defer tmp.deinit();
            sv.compactWithBuffer(try tmp.getDataMut()) catch {
                try sv.compactInPlace();
            };
        }

        pub fn append(self: *Self, val: ValueIn) Error!PageId {
            if (self.last_chunk) |*last_c| {
                const total = try self.mgr.getTotalSize();
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

                        var pv = try last_c.viewMut();
                        var nv = try next.viewMut();
                        pv.setNext(next_id);
                        nv.setPrev(try last_c.id());

                        try self.mgr.setLast(next_id);
                        try self.mgr.setTotalSize(total + 1);

                        last_c.deinit();
                        self.last_chunk = next;

                        return next_id;
                    },
                    .enough => {},
                }

                _ = try sd.insert(val);
                try self.mgr.setTotalSize(total + 1);
                return try last_c.id();
            } else {
                var page = try self.createPage();
                errdefer page.deinit();
                const page_id = try page.id();
                var sd = try page.slotsDirMut();
                _ = try sd.insert(val);
                try self.mgr.setFirst(page_id);
                try self.mgr.setLast(page_id);
                try self.mgr.setTotalSize(1);
                self.last_chunk = page;
                return page_id;
            }
        }

        pub fn size(self: *const Self) Error!usize {
            return self.mgr.getTotalSize();
        }

        pub fn iterator(self: *const Self) Error!?Iterator {
            const first = (try self.mgr.getFirst()) orelse return null;
            return try Iterator.init(self.page_cache, first, .before_first);
        }

        pub fn iteratorFromEnd(self: *const Self) Error!?Iterator {
            const last = (try self.mgr.getLast()) orelse return null;
            return try Iterator.init(self.page_cache, last, .after_last);
        }

        pub fn loadPage(self: *const Self, pid: PageId) Error!ChunkHandle {
            const page_handle = try self.page_cache.fetch(pid);
            return ChunkHandle.init(page_handle);
        }

        pub fn createPage(self: *Self) Error!ChunkHandle {
            const ph = try self.page_cache.create();
            var ch = ChunkHandle.init(ph);
            var v = try ch.viewMut();
            try v.formatPage(self.settings.chunk_page_kind, try ch.ph.pid(), 0);
            return ch;
        }

        fn removeChunkFromList(self: *Self, ch: *ChunkHandle) Error!void {
            var v = try ch.viewMut();
            const next = v.getNext();
            const prev = v.getPrev();

            var the_last = false;
            //var the_first = false;

            if (self.last_chunk) |*last_c| {
                the_last = (try last_c.id()) == (try ch.ph.pid());
            }

            if (prev) |prev_id| {
                var prev_page = try self.page_cache.fetch(prev_id);
                errdefer prev_page.deinit();
                var prev_v = try ChunkView.init(try prev_page.getDataMut());
                prev_v.setNext(next);
                if (the_last) {
                    self.last_chunk = prev_page;
                } else {
                    prev_page.deinit();
                }
            } else {
                try self.mgr.setFirst(next);
            }

            if (next) |next_id| {
                var next_page = try self.page_cache.fetch(next_id);
                defer next_page.deinit();
                var next_v = try ChunkView.init(try next_page.getDataMut());
                next_v.setPrev(prev);
            } else {
                try self.mgr.setLast(prev);
            }
        }
    };
}
