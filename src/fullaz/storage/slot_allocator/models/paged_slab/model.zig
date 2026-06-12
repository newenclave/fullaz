const std = @import("std");
const page = @import("../../../../page/slab_allocator.zig");
const view = @import("view.zig");
const errors = @import("../../../../core/errors.zig");

pub const Settings = struct {
    page_kind: u16 = 1,
};

pub fn Model(comptime PageCacheType: type, comptime SlabStorageManagerT: type, comptime SizeClassT: type) type {
    const BlockDevice = PageCacheType.UnderlyingDevice;
    const PageHandle = PageCacheType.Handle;
    const PidT = BlockDevice.BlockId;

    const View = view.View(PidT, u16, u16, .little, false).SlabPageView;
    const ConstView = view.View(PidT, u16, u16, .little, true).SlabPageView;

    const Context = struct {
        const Self = @This();
        page_cache: *PageCacheType,
        slab_storage_manager: *SlabStorageManagerT,
        settings: Settings,
    };

    const SlabPageImpl = struct {
        const Self = @This();
        const Error = PageCacheType.Error || SlabStorageManagerT.Error;

        ctx: *Context = undefined,
        ph: PageHandle = undefined,

        fn init(ctx: *Context, ph: PageHandle) Error!Self {
            return Self{
                .ctx = ctx,
                .ph = ph,
            };
        }

        pub fn deinit(self: *Self) void {
            self.ph.deinit();
            self.* = undefined;
        }
    };

    return struct {
        const Self = @This();
        pub const Error = PageCacheType.Error ||
            SlabStorageManagerT.Error ||
            View.Error ||
            errors.PageError;

        ctx: Context = undefined,

        pub const PageCache = PageCacheType;
        pub const SlabStorageManager = SlabStorageManagerT;
        pub const SizeClass = SizeClassT;

        pub fn init(page_cache: *PageCacheType, slab_storage_manager: *SlabStorageManagerT, settings: Settings) Error!Self {
            return Self{
                .ctx = Context{
                    .page_cache = page_cache,
                    .slab_storage_manager = slab_storage_manager,
                    .settings = settings,
                },
            };
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn fetch(self: *Self, pid: PidT) Error!SlabPageImpl {
            var ph = try self.ctx.page_cache.fetch(pid);
            errdefer ph.deinit();
            var impl = try SlabPageImpl.init(&self.ctx, ph);
            var pv = ConstView.init(try impl.ph.getData());
            defer pv.deinit();
            if (pv.page_view.header().kind.get() != self.ctx.settings.page_kind) {
                impl.deinit();
                return Error.InvalidId;
            }
            return impl;
        }

        pub fn createPage(self: *Self, sclass: SizeClassT) Error!SlabPageImpl {
            var ph = try self.ctx.page_cache.create();
            errdefer ph.deinit();
            var impl = try SlabPageImpl.init(&self.ctx, ph);
            var pv = View.init(try impl.ph.getDataMut());
            defer pv.deinit();
            try pv.formatPage(
                self.ctx.settings.page_kind,
                try ph.pid(),
                0,
                sclass,
            );
            return impl;
        }
    };
}
