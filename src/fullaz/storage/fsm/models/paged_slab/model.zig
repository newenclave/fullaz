const std = @import("std");
const page = @import("../../../../page/fsm.zig");
const view = @import("view.zig");
const errors = @import("../../../../core/errors.zig");

pub const Settings = struct {
    page_kind: u16 = 1,
};

pub fn Model(comptime PageCacheType: type, comptime SlabStorageManagerT: type, comptime SizePolicyT: type) type {
    const BlockDevice = PageCacheType.UnderlyingDevice;
    const PageHandle = PageCacheType.Handle;
    const PidT = BlockDevice.BlockId;
    const SizeClassT = SizePolicyT.SizeClass;

    const View = view.View(PidT, u16, u16, .little, false).SlabPageView;
    const ConstView = view.View(PidT, u16, u16, .little, true).SlabPageView;

    const Context = struct {
        const Self = @This();
        page_cache: *PageCacheType,
        slab_storage_manager: *SlabStorageManagerT,
        size_policy: SizePolicyT,
        settings: Settings,
    };

    const CommonPage = struct {
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

        pub fn headerMut(self: *Self) Error!View.PageView.PageHeader {
            return View.PageView.init(try self.ph.getDataMut()).headerMut();
        }

        pub fn header(self: *const Self) Error!*const ConstView.PageView.PageHeader {
            return ConstView.PageView.init(try self.ph.getData()).header();
        }
    };

    const SlabPageImpl = struct {
        const Self = @This();
        const Error = PageCacheType.Error ||
            SlabStorageManagerT.Error ||
            View.Error;
        const SlotInfo = View.SlotInfo;

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

        pub fn findPageWithSpace(self: *Self, full_size: SizeClassT) Error!?SlotInfo {
            var pv = ConstView.init(try self.ph.getData());
            defer pv.deinit();
            return try pv.findBySize(full_size);
        }

        pub fn freeSlot(self: *Self, slot: usize) Error!void {
            var pv = View.init(try self.ph.getDataMut());
            defer pv.deinit();
            try pv.remove(slot);
        }

        pub fn isFull(self: *const Self) Error!bool {
            var pv = ConstView.init(try self.ph.getData());
            defer pv.deinit();
            return try pv.isFull();
        }

        pub fn isEmpty(self: *const Self) Error!bool {
            var pv = ConstView.init(try self.ph.getData());
            defer pv.deinit();
            return try pv.isEmpty();
        }

        pub fn fetchCommonPage(self: *Self, pid: PidT) Error!CommonPage {
            var ph = try self.ctx.page_cache.fetch(pid);
            errdefer ph.deinit();
            return try CommonPage.init(self.ctx, ph);
        }

        pub fn setPageFsmInfo(self: *Self, slot_info: *const SlotInfo) Error!void {
            var pv = View.init(try self.ph.getDataMut());
            defer pv.deinit();
            var header = pv.pageHeaderMut();
            header.fsm_index.page_id.set(slot_info.pid);
            header.fsm_index.index.set(@as(u16, slot_info.slot_id));
        }

        pub fn sizeClass(self: *const Self) Error!SizeClassT {
            var pv = ConstView.init(try self.ph.getData());
            defer pv.deinit();
            return pv.sizeClass();
        }

        pub fn id(self: *const Self) Error!PidT {
            var pv = ConstView.init(try self.ph.getData());
            defer pv.deinit();
            return pv.pageHeader().self_pid.get();
        }

        pub fn hasNext(self: *Self) Error!bool {
            var pv = ConstView.init(try self.ph.getData());
            defer pv.deinit();
            return pv.getNext() != null;
        }

        pub fn fetchNext(self: *Self) Error!?Self {
            var pv = ConstView.init(try self.ph.getData());
            defer pv.deinit();
            if (pv.getNext()) |next_pid| {
                var ph = try self.ctx.page_cache.fetch(next_pid);
                errdefer ph.deinit();
                if (pv.page_view.header().kind.get() != self.ctx.settings.page_kind) {
                    return Error.InvalidId;
                }
                return try Self.init(self.ctx, ph);
            }
            return null;
        }

        pub fn insert(self: *Self, pid: PidT, free_space: SizeClassT) Error!SlotInfo {
            var pv = View.init(try self.ph.getDataMut());
            defer pv.deinit();
            var slot_index = try pv.insert(pid, free_space);

            slot_index.pid = try self.id();

            return slot_index;
        }

        pub fn insertBefore(self: *Self, old_root: *Self) Error!void {
            var pv = View.init(try self.ph.getDataMut());
            defer pv.deinit();
            var old_pv = View.init(try old_root.ph.getDataMut());
            defer old_pv.deinit();

            try pv.setNext(try old_root.id());
            try pv.setPrev(null); // just in case
            try old_pv.setPrev(try self.id());
        }

        pub fn getNext(self: *const Self) Error!?PidT {
            var pv = ConstView.init(try self.ph.getData());
            defer pv.deinit();
            return pv.getNext();
        }

        pub fn removeFromList(self: *Self) Error!void {
            var pv = View.init(try self.ph.getDataMut());
            defer pv.deinit();
            const prev = pv.getPrev();
            const next = pv.getNext();
            if (prev) |prev_id| {
                var prev_page = try self.ctx.page_cache.fetch(prev_id);
                defer prev_page.deinit();
                var prev_impl = try Self.init(self.ctx, prev_page);
                defer prev_impl.deinit();
                var prev_pv = View.init(try prev_impl.ph.getDataMut());
                defer prev_pv.deinit();
                try prev_pv.setNext(next);
            }
            if (next) |next_id| {
                var next_page = try self.ctx.page_cache.fetch(next_id);
                defer next_page.deinit();
                var next_impl = try Self.init(self.ctx, next_page);
                defer next_impl.deinit();
                var next_pv = View.init(try next_impl.ph.getDataMut());
                defer next_pv.deinit();
                try next_pv.setPrev(prev);
            }
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
        pub const SizePolicy = SizePolicyT;
        pub const SizeClass = SizeClassT;

        pub const Pid = PidT;
        pub const Size = SizeClass;
        pub const SlotInfo = View.SlotInfo;

        pub fn init(page_cache: *PageCacheType, slab_storage_manager: *SlabStorageManagerT, size_policy: SizePolicyT, settings: Settings) Error!Self {
            return .{
                .ctx = Context{
                    .page_cache = page_cache,
                    .slab_storage_manager = slab_storage_manager,
                    .size_policy = size_policy,
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

        pub fn createPage(self: *Self, sclass: Size) Error!SlabPageImpl {
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

        pub fn getPageSizeClass(self: *Self, class: Size) Error!?SlabPageImpl {
            if (try self.ctx.slab_storage_manager.getSizeClassRoot(class)) |p| {
                return try self.fetch(p);
            }
            return null;
        }

        pub fn add(self: *Self, pid: Pid, size: Size) Error!SlotInfo {
            const sclass = try self.ctx.size_policy.getSizeClass(size);

            const root_page = try self.getPageSizeClass(sclass);
            var impl: SlabPageImpl = undefined;
            defer impl.deinit();

            if (root_page) |sp| {
                impl = sp;
                while (try impl.isFull()) {
                    if (try impl.fetchNext()) |next_impl| {
                        impl.deinit();
                        impl = next_impl;
                    } else {
                        var new_page = try self.createPage(sclass);
                        errdefer new_page.deinit();
                        try new_page.insertBefore(&impl);
                        try self.ctx.slab_storage_manager.setSizeClassRoot(sclass, try new_page.id());
                        impl.deinit();
                        impl = new_page;
                    }
                }
            } else {
                var new_page = try self.createPage(sclass);
                errdefer new_page.deinit();
                try self.ctx.slab_storage_manager.setSizeClassRoot(sclass, try new_page.id());
                impl = new_page;
            }
            return try impl.insert(pid, size);
        }

        pub fn remove(self: *Self, slot_info: *const SlotInfo) Error!void {
            var pv = try self.fetch(slot_info.pid);
            defer pv.deinit();
            try pv.freeSlot(slot_info.slot_id);
            const sclass = pv.sizeClass();
            if (try pv.isEmpty()) {
                try pv.removeFromList();
                try self.ctx.slab_storage_manager.destroyPage(try pv.id());
            }
            const size_root = try self.ctx.slab_storage_manager.getSizeClassRoot(sclass);
            if (size_root) |sr| {
                if (sr == slot_info.pid) {
                    try self.ctx.slab_storage_manager.setSizeClassRoot(sclass, try pv.getNext());
                }
            } else {
                try self.ctx.slab_storage_manager.setSizeClassRoot(sclass, try pv.getNext());
            }
        }
    };
}
