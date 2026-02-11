const std = @import("std");
const device_interface = @import("../../../device/interfaces.zig");
const page_cache = @import("../../../storage/page_cache.zig");
const wbpt_page = @import("view.zig");
const contracts = @import("../../../contracts/contracts.zig");
const core = @import("../../../core/core.zig");
const errors = core.errors;

pub const Settings = struct {
    maximum_value_size: usize = 128,
    leaf_page_kind: u16 = 0,
    inode_page_kind: u16 = 1,
};

pub fn PagedModel(comptime PageCacheType: type, comptime StorageManager: type, comptime ValuePolicy: type) type {
    comptime {
        contracts.storage_manager.requiresStorageManager(StorageManager);
        contracts.page_cache.requiresPageCache(PageCacheType);
    }

    const BlockDevice = PageCacheType.UnderlyingDevice;
    const PageHandle = PageCacheType.Handle;
    const BlockIdType = BlockDevice.BlockId;
    const Weight = u32;
    const Index = u16;

    const ValuePolicyType = ValuePolicy;
    _ = ValuePolicyType;

    const Value = []const u8;

    const WBptPage = wbpt_page.View(BlockIdType, Index, Weight, .little, false);
    const WBptPageConst = wbpt_page.View(BlockIdType, Index, Weight, .little, true);

    const Context = struct {
        cache: *PageCacheType = undefined,
        storage_mgr: *StorageManager = undefined,
        settings: Settings = undefined,
    };

    const ValueViewImpl = struct {
        const Self = @This();
        pub fn init(_: Value) Self {
            return Self{};
        }
        pub fn deinit() void {}
    };

    const ErrorSet = errors.PageError ||
        errors.SlotsError ||
        PageCacheType.Error ||
        errors.OrderError ||
        errors.BptError;

    const LeafImpl = struct {
        const Self = @This();
        const PageViewType = WBptPage.LeafSubheaderView;
        const PageViewTypeConst = WBptPageConst.LeafSubheaderView;
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

        pub fn deinit(self: *Self) void {
            self.handle.deinit();
        }
    };

    const InodeImpl = struct {
        const Self = @This();
        const PageViewType = WBptPage.InodeSubheaderView;
        const PageViewTypeConst = WBptPageConst.InodeSubheaderView;

        pub const Error = ErrorSet;

        handle: PageHandle = undefined,
        self_id: BlockIdType = undefined,
        ctx: *Context = undefined,

        fn init(ph: PageHandle, self_id: BlockIdType, ctx: *Context) Self {
            return .{
                .handle = ph,
                .self_id = self_id,
                .ctx = ctx,
            };
        }

        pub fn deinit(self: *Self) void {
            self.handle.deinit();
        }
    };

    const AccessorImpl = struct {
        const Self = @This();

        pub const Error = ErrorSet;

        ctx: Context = undefined,

        fn init(ctx: Context) Self {
            return .{
                .ctx = ctx,
            };
        }

        pub fn deinit(_: Self) void {
            // nothing to do yet
        }
    };

    return struct {
        const Self = @This();

        pub const AccessorType = AccessorImpl;
        pub const WeightType = Weight;
        pub const NodePositionType = Index;
        pub const Error = ErrorSet;

        pub const ValueViewType = ValueViewImpl;
        pub const ValueType = Value;

        pub const LeafType = LeafImpl;
        pub const InodeType = InodeImpl;

        pub const NodeIdType = BlockIdType;

        accessor: AccessorType,

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
        }
    };
}
