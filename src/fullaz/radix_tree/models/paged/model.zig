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
    const Context = struct {
        cache: *PageCacheType = undefined,
        storage_mgr: *StorageManager = undefined,
        settings: Settings = undefined,
    };

    const BlockDevice = PageCacheType.UnderlyingDevice;
    const PageHandle = PageCacheType.Handle;
    const BlockIdType = BlockDevice.BlockId;
    const Index = u16;

    const ViewType = radix_page.View(BlockIdType, Index, Key, @sizeOf(Value), std.builtin.endian, false);
    const ConstViewType = radix_page.View(BlockIdType, Index, Key, @sizeOf(Value), std.builtin.endian, true);

    _ = PageHandle;
    _ = ViewType;
    _ = ConstViewType;

    const LeafImpl = struct {};
    const InodeImpl = struct {};
    const AccessorImpl = struct {
        const Self = @This();

        ctx: Context = undefined,

        fn init(ctx: Context) Self {
            return .{
                .ctx = ctx,
            };
        }

        fn deinit(self: *Self) void {
            self.* = undefined;
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
