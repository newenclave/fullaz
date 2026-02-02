const std = @import("std");
const view = @import("view.zig");
const page_header = @import("../../page/header.zig");
const interfaces = @import("../../contracts/contracts.zig");
const errors = @import("../../core/errors.zig");
const requiresRopeHeaderManager = @import("interfaces.zig").requiresRopeHeaderManager;

pub const Settings = struct {
    chunk_page_kind: u16 = 0x21,
};

pub fn Handle(comptime PageCacheType: type, comptime RopeHeaderManager: type) type {
    comptime {
        interfaces.page_cache.requiresPageCache(PageCacheType);
        requiresRopeHeaderManager(RopeHeaderManager);
    }

    const PosType = RopeHeaderManager.Size;
    const Index = u16;
    const BlockDevice = PageCacheType.UnderlyingDevice;
    const PageHandle = PageCacheType.Handle;
    const BlockIdType = BlockDevice.BlockId;

    //    const CommonPageView = page_header.View(BlockIdType, u16, .little, false);
    const CommonPageViewConst = page_header.View(BlockIdType, Index, .little, true);
    const ViewTypes = view.View(BlockIdType, Index, PosType, .little, false);
    const ViewTypesConst = view.View(BlockIdType, Index, PosType, .little, true);

    const CommonErrors = PageCacheType.Error ||
        RopeHeaderManager.Error;

    const Context = struct {
        cache: *PageCacheType,
        mgr: *RopeHeaderManager,
        settings: Settings,
    };

    const Cursor = struct {
        const Self = @This();
        const ViewType = ViewTypes.ChunkView;
        const ViewTypeConst = ViewTypesConst.ChunkView;

        pub const Error = PageCacheType.Error ||
            CommonErrors ||
            errors.PageError;

        handle: ?PageHandle = null,
        ctx: *Context = undefined,
        pos: Index = 0,

        pub fn init(ph: ?PageHandle, pos: Index, ctx: *Context) Self {
            return Self{
                .handle = ph,
                .ctx = ctx,
                .pos = pos,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.handle) |ph_const| {
                var ph = ph_const;
                ph.deinit();
                self.handle = null;
            }
        }

        fn view(self: *const Self) Error!ViewTypeConst {
            return ViewTypeConst.init(try self.handle.getData());
        }

        fn viewMut(self: *Self) Error!ViewType {
            return ViewType.init(try self.handle.getDataMut());
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
        pub fn init(cache: *PageCacheType, mgr: *RopeHeaderManager, settings: Settings) Self {
            var result = Self{};
            result.ctx.cache = cache;
            result.ctx.mgr = mgr;
            result.ctx.settings = settings;

            return result;
        }

        fn fetch(self: *Self, page_id: Pid) Error!PageHandle {
            const ph = try self.ctx.cache.fetch(page_id);
            errdefer ph.deinit();
            const pv = CommonPageViewConst.init(ph.getData());
            if (pv.header().kind.get() != self.ctx.settings.chunk_page_kind) {
                return errors.PageError.BadType;
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
