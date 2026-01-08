const std = @import("std");
const device_interface = @import("../../device/interfaces.zig");

fn PagedModel(comptime BlockDevice: type) type {
    device_interface.assertBlockDevice(BlockDevice);

    return struct {
        const Self = @This();
        pub const KeyLikeType = []const u8;
        pub const KeyOutType = []const u8;

        pub const ValueInType = []const u8;
        pub const ValueOutType = []const u8;

        pub const BlockDeviceType = BlockDevice;
        device: *BlockDeviceType = undefined,

        pub fn init(device: *BlockDeviceType) Self {
            return .{
                .device = device,
            };
        }
        pub fn deinit() void {
            // nothing to yet
        }
    };
}
