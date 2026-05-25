const std = @import("std");
const core = @import("../../../core/core.zig");
const errors = core.errors;
const SubheaderView = @import("view.zig").View;

pub const Settings = struct {
    max_level: usize,
};

pub fn Paged(comptime PageCacheType: type, comptime StorageManager: type, comptime cmp: anytype, comptime Ctx: type) type {
    const BlockDevice = PageCacheType.UnderlyingDevice;
    const PageHandle = PageCacheType.Handle;
    const BlockIdType = BlockDevice.BlockId;

    _ = cmp;

    const ContextImpl = struct {
        const Self = @This();
        settings: Settings,
        rng: std.Random = undefined,
        cache: *PageCacheType = undefined,
        storage: *StorageManager = undefined,
        cmp_ctx: Ctx = undefined,
    };

    const PidImpl = struct {
        const Self = @This();
        page_id: BlockIdType,
        slot_id: usize,
    };

    const NodeImpl = struct {
        const Self = @This();
        pid: PidImpl,
        ph: PageHandle,
        fn init(ph: PageHandle, pid: PidImpl) Self {
            return Self{
                .pid = pid,
                .ph = ph,
            };
        }
    };

    const AccessorImpl = struct {
        const Self = @This();
        const Pid = PidImpl;
        context: ContextImpl,
        fn init(ctx: ContextImpl) Self {
            return Self{
                .context = ctx,
            };
        }
    };

    return struct {
        const Self = @This();

        pub const Error = PageCacheType.Error || StorageManager.Error;

        pub const Accessor = AccessorImpl;
        pub const Node = NodeImpl;
        pub const Pid = PidImpl;
        // pub const KeyIn = KeyT;
        // pub const ValueIn = ValueT;

        // pub const KeyOut = *const KeyIn;
        // pub const ValueOut = *const ValueIn;
        // pub const Path = PathImpl;

        accessor: AccessorImpl,

        pub fn init(device: *PageCacheType, storage_mgr: *StorageManager, settings: Settings, ctx: Ctx, rng: std.Random) Self {
            return Self{
                .accessor = AccessorImpl.init(ContextImpl{
                    .settings = settings,
                    .rng = rng,
                    .cache = device,
                    .storage = storage_mgr,
                    .cmp_ctx = ctx,
                }),
            };
        }
        pub fn deinit(self: *Self) void {
            self.accessor = undefined; // Clear the accessor to release references to resources.
        }
    };

    //const BlockDevice = PageCacheType.UnderlyingDevice;
    // const PageHandle = PageCacheType.Handle;
    // const BlockIdType = BlockDevice.BlockId;
}
