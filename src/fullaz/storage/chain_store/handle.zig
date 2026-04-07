const std = @import("std");
const view = @import("view.zig");
const page_header = @import("../../page/header.zig");
const interfaces = @import("../../contracts/contracts.zig");
const errors = @import("../../core/errors.zig");
const requiresStorageManager = @import("interfaces.zig").requiresStorageManager;

pub const Settings = struct {
    chunk_page_kind: u16 = 0x21,
};

// const StorageManager = struct {
//     const Error = error{};
//     const PageId = u64;
//     const Size = u64;
//     fn getTotalSize(self: *const StorageManager) Error!Size;
//     fn setTotalSize(self: *StorageManager, size: Size) Error!void;
//     fn getFirst(self: *const StorageManager) Error!?PageId;
//     fn getLast(self: *const StorageManager) Error!?PageId;
//     fn setFirst(self: *StorageManager, page_id: ?PageId) Error!void;
//     fn setLast(self: *StorageManager, page_id: ?PageId) Error!void;
//     fn destroyPage(self: *StorageManager, page_id: PageId) void;
// };

pub fn Handle(comptime PageCacheType: type, comptime StorageManager: type) type {
    comptime {
        interfaces.page_cache.requiresPageCache(PageCacheType);
        requiresStorageManager(StorageManager);
    }

    const PosType = StorageManager.Size;
    const Index = u16;
    const BlockDevice = PageCacheType.UnderlyingDevice;
    const PageHandle = PageCacheType.Handle;
    const BlockIdType = BlockDevice.BlockId;

    //    const CommonPageView = page_header.View(BlockIdType, u16, .little, false);
    const CommonPageViewConst = page_header.View(BlockIdType, Index, .little, true);
    const ViewTypes = view.View(BlockIdType, Index, PosType, .little, false);
    const ViewTypesConst = view.View(BlockIdType, Index, PosType, .little, true);

    const CommonErrors = PageCacheType.Error ||
        StorageManager.Error;

    const Context = struct {
        cache: *PageCacheType,
        mgr: *StorageManager,
        settings: Settings,
    };

    const Cursor = union(enum) {
        before_begin,
        on: Index,
        after_end,
    };

    const Iterator = struct {
        const Self = @This();
        hanlde: ?PageHandle,
        pos: Cursor,
        fn init(hanlde: PageHandle) Self {
            return Self{
                .hanlde = hanlde,
                .pos = .before_begin,
            };
        }

        fn initPos(hanlde: PageHandle, pos: Cursor) Self {
            return Self{
                .hanlde = hanlde,
                .pos = pos,
            };
        }

        fn deinit(self: *Self) void {
            if (self.hanlde) |ph| {
                ph.deinit();
            }
        }
    };

    return struct {
        const Self = @This();

        pub const Pid = BlockIdType;
        pub const Error = PageCacheType.Error ||
            CommonErrors ||
            errors.PageError;

        const Position = struct {
            page_id: Pid,
            pos: Index = 0,
            total_pos: usize = 0,
        };

        g_pos: ?Position = null,
        p_pos: ?Position = null,

        ctx: Context,

        pub const View = view.View;
        pub fn init(cache: *PageCacheType, mgr: *StorageManager, settings: Settings) Self {
            var result = Self{};
            result.ctx.cache = cache;
            result.ctx.mgr = mgr;
            result.ctx.settings = settings;

            return result;
        }

        pub fn iterator(_: *const Self) Iterator {
            return Iterator{};
        }

        fn fetch(self: *Self, page_id: Pid) Error!PageHandle {
            const ph = try self.ctx.cache.fetch(page_id);
            errdefer ph.deinit();
            const pv = CommonPageViewConst.init(ph.getData());
            if (pv.header().kind.get() != self.ctx.settings.chunk_page_kind) {
                return errors.BadType;
            }
            return ph;
        }

        fn create(self: *Self) Error!PageHandle {
            const ph = try self.ctx.cache.create();
            errdefer ph.deinit();
            var pv = ViewTypes.Chunk.init(try ph.getDataMut());
            pv.formatPage(self.ctx.settings.chunk_page_kind, ph.pid(), 0);
            return ph;
        }

        fn insertBefore(self: *Self, pid_before: Pid, ph: *PageHandle) Error!void {
            const pid = try ph.pid();

            const ph_before = try self.fetch(pid_before);
            defer ph_before.deinit();
            const pv_before_c = ViewTypesConst.Chunk.init(try ph_before.getData());

            const prev = pv_before_c.getPrev();
            if (prev) |prev_id| {
                const ph_prev = try self.fetch(prev_id);
                defer ph_prev.deinit();
                var pv_prev = ViewTypes.Chunk.init(try ph_prev.getDataMut());
                pv_prev.setNext(pid);
            } else {
                try self.ctx.mgr.setFirst(pid);
            }
            var pv = ViewTypes.Chunk.init(try ph.getDataMut());
            var pv_before = ViewTypes.Chunk.init(try ph_before.getDataMut());
            pv.setPrev(prev);
            pv.setNext(pid_before);
            pv_before.setPrev(pid);
        }

        fn insertAfter(self: *Self, pid_after: Pid, ph: *PageHandle) Error!void {
            const pid = try ph.pid();

            const ph_after = try self.fetch(pid_after);
            defer ph_after.deinit();
            const pv_after_c = ViewTypesConst.Chunk.init(try ph_after.getData());

            const next = pv_after_c.getNext();
            if (next) |next_id| {
                const ph_next = try self.fetch(next_id);
                defer ph_next.deinit();
                var pv_next = ViewTypes.Chunk.init(try ph_next.getDataMut());
                pv_next.setPrev(pid);
            } else {
                try self.ctx.mgr.setLast(pid);
            }
            var pv = ViewTypes.Chunk.init(try ph.getDataMut());
            var pv_after = ViewTypes.Chunk.init(try ph_after.getDataMut());
            pv.setNext(next);
            pv.setPrev(pid_after);
            pv_after.setNext(pid);
        }

        fn removeChunk(self: *Self, ph: *PageHandle) Error!void {
            var pv = ViewTypesConst.Chunk.init(try ph.getData());
            const prev = pv.getPrev();
            const next = pv.getNext();
            if (prev) |prev_id| {
                const ph_prev = try self.fetch(prev_id);
                defer ph_prev.deinit();
                var pv_prev = ViewTypes.Chunk.init(try ph_prev.getDataMut());
                pv_prev.setNext(next);
            } else {
                try self.ctx.mgr.setFirst(next);
            }
            if (next) |next_id| {
                const ph_next = try self.fetch(next_id);
                defer ph_next.deinit();
                var pv_next = ViewTypes.Chunk.init(try ph_next.getDataMut());
                pv_next.setPrev(prev);
            } else {
                try self.ctx.mgr.setLast(prev);
            }
            self.ctx.mgr.destroyPage(try ph.pid());
        }
    };
}
