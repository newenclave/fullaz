const std = @import("std");
const view = @import("view.zig");

pub const Settings = struct {
    chunk_page_kind: u16 = 0x21,
    index_leaf_page_kind: u16 = 0,
    index_inode_page_kind: u16 = 1,
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

        pub fn compact(self: *Self, tmp_buf: []u8) Error!void {
            var sd = try self.slotsDirMut();
            sd.compactWithBuffer(tmp_buf) catch {
                try sd.compactInPlace();
            };
        }
    };

    return struct {
        const Self = @This();
        pub const PageId = BlockIdType;
        pub const Index = IndexT;
        pub const View = ViewType;
        pub const Error = PageCacheType.Error ||
            ViewType.Error ||
            StorageManager.Error;
        pub const ValueIn = []const u8;
        pub const ValueOut = []const u8;

        page_cache: *PageCacheType,
        mgr: *StorageManager,
        settings: Settings = .{},

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
            _ = self;
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
            if (try self.mgr.getLast()) |last| {
                const total = try self.mgr.getTotalSize();
                var page = try self.loadPage(last);
                defer page.deinit();
                var sd = try page.slotsDirMut();
                switch (try sd.canInsert(val.len)) {
                    .need_compact => {
                        try self.compactPage(&page);
                    },
                    .not_enough => {
                        var next = try self.createPage();
                        defer next.deinit();
                        const next_id = try next.id();
                        var next_sd = try next.slotsDirMut();
                        _ = try next_sd.insert(val);

                        var pv = try page.viewMut();
                        var nv = try next.viewMut();
                        pv.setNext(next_id);
                        nv.setPrev(last);

                        try self.mgr.setLast(next_id);
                        try self.mgr.setTotalSize(total + 1);
                        return next_id;
                    },
                    .enough => {},
                }

                _ = try sd.insert(val);
                try self.mgr.setTotalSize(total + 1);
                return last;
            } else {
                var page = try self.createPage();
                defer page.deinit();
                const page_id = try page.id();
                var sd = try page.slotsDirMut();
                _ = try sd.insert(val);
                try self.mgr.setFirst(page_id);
                try self.mgr.setLast(page_id);
                try self.mgr.setTotalSize(1);
                return page_id;
            }
        }

        pub fn size(self: *const Self) Error!usize {
            return self.mgr.getTotalSize();
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
    };
}
