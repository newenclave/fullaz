const std = @import("std");
const device_interface = @import("../../../device/interfaces.zig");
const page_cache = @import("../../../storage/page_cache.zig");
const radix_page = @import("view.zig");
const contracts = @import("../../../contracts/contracts.zig");
const core = @import("../../../core/core.zig");
const errors = core.errors;
const KeySplitter = @import("../../splitter.zig").Splitter;

pub const Settings = struct {
    leaf_page_kind: u16 = 0,
    inode_page_kind: u16 = 1,
};

pub fn Model(comptime PageCacheType: type, comptime StorageManager: type, comptime Key: type, comptime Value: type) type {
    comptime {
        contracts.storage_manager.requiresStorageManager(StorageManager);
        contracts.page_cache.requiresPageCache(PageCacheType);
    }

    const Context = struct {
        cache: *PageCacheType = undefined,
        storage_mgr: *StorageManager = undefined,
        settings: Settings = undefined,
    };

    const ErrorSet = errors.PageError ||
        errors.SlotsError ||
        PageCacheType.Error ||
        errors.BufferError ||
        errors.OrderError;

    const BlockDevice = PageCacheType.UnderlyingDevice;
    const PageHandle = PageCacheType.Handle;
    const BlockIdType = BlockDevice.BlockId;
    const Index = u16;

    const ViewType = radix_page.View(BlockIdType, Index, Key, @sizeOf(Value), .little, false);
    const ConstViewType = radix_page.View(BlockIdType, Index, Key, @sizeOf(Value), .little, true);

    const LeafImpl = struct {
        const Self = @This();
        const PageViewType = ViewType.LeafSubheaderView;
        const PageViewTypeConst = ConstViewType.LeafSubheaderView;

        handle: PageHandle = undefined,
        self_id: BlockIdType = undefined,
        ctx: *Context = undefined,

        pub const Error = ErrorSet;

        fn init(ph: PageHandle, self_id: BlockIdType, ctx: *Context) Self {
            return .{
                .handle = ph,
                .self_id = self_id,
                .ctx = ctx,
            };
        }

        fn deinit(self: *Self) void {
            self.handle.deinit();
            self.* = undefined;
        }

        pub fn id(self: *const Self) BlockIdType {
            return self.self_id;
        }
    };

    const InodeImpl = struct {};
    const AccessorImpl = struct {
        const Self = @This();
        const Error = ErrorSet;

        ctx: Context = undefined,

        fn init(ctx: Context) Self {
            return .{
                .ctx = ctx,
            };
        }

        fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn createLeaf(self: *Self) ErrorSet!LeafImpl {
            var ph = try self.ctx.cache.create();
            defer ph.deinit();
            const pid = try ph.pid();
            var page_view = LeafImpl.PageViewType.init(try ph.getDataMut());
            try page_view.formatPage(self.ctx.settings.leaf_page_kind, pid, 0);
            return LeafImpl.init(try ph.take(), pid, &self.ctx);
        }

        pub fn loadLeaf(self: *Self, id: BlockIdType) ErrorSet!LeafImpl {
            var ph = try self.ctx.cache.fetch(id);
            defer ph.deinit();
            const pid = try ph.pid();
            var view = LeafImpl.PageViewTypeConst.init(try ph.getData());
            if (view.page_view.header().kind.get() != self.ctx.settings.leaf_page_kind) {
                return Error.BadType;
            }
            try view.check();
            return LeafImpl.init(try ph.take(), pid, &self.ctx);
        }

        pub fn deinitLeaf(_: *Self, leaf: *LeafImpl) void {
            leaf.deinit();
            leaf.* = undefined;
        }
    };

    return struct {
        const Self = @This();
        pub const Leaf = LeafImpl;
        pub const Inode = InodeImpl;
        pub const Accessor = AccessorImpl;

        accessor: Accessor = undefined,

        pub fn init(device: *PageCacheType, storage_mgr: *StorageManager, settings: Settings) Self {
            const context = Context{
                .cache = device,
                .storage_mgr = storage_mgr,
                .settings = settings,
            };
            return .{
                .accessor = AccessorImpl.init(context),
            };
        }

        pub fn deinit(self: *Self) void {
            self.accessor.deinit();
            self.* = undefined;
        }
    };
}
