const std = @import("std");
const device_interface = @import("../../device/interfaces.zig");
const page_cache = @import("../../page_cache.zig");

pub fn PagedModel(comptime PageCacheType: type) type {
    const BlockDevice = PageCacheType.UnderlyingDevice;
    const PageHandle = PageCacheType.Handle;
    const BlockIdType = BlockDevice.BlockId;

    _ = PageHandle;

    const AccessorImpl = struct {
        const Self = @This();
        pub const PageCache = PageCacheType;
        device: *PageCache = undefined,
        fn init(device: *PageCacheType) Self {
            return .{
                .device = device,
            };
        }
    };

    const LeafImpl = struct {};
    const InodeImpl = struct {};

    const KeyBorrowImpl = struct {
        const Self = @This();
        key: []const u8,
    };

    return struct {
        const Self = @This();
        pub const KeyLikeType = []const u8;
        pub const KeyOutType = []const u8;

        pub const ValueInType = []const u8;
        pub const ValueOutType = []const u8;

        pub const KeyBorrowType = KeyBorrowImpl;

        pub const BlockDeviceType = BlockDevice;
        pub const AccessorType = AccessorImpl;

        pub const LeafType = LeafImpl;
        pub const InodeType = InodeImpl;

        pub const NodeIdType = BlockIdType;

        accessor: AccessorType,

        pub fn init(device: *PageCacheType) Self {
            return .{
                .accessor = AccessorImpl.init(device),
            };
        }

        pub fn deinit() void {
            // nothing to yet
        }
    };
}
