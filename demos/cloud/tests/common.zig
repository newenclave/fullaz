const std = @import("std");
const fullaz = @import("fullaz");

pub const cloud = @import("cloud");

pub const Device = fullaz.device.MemoryBlock(cloud.constants.PageId);
pub const PageCache = fullaz.storage.page_cache.PageCache(Device);

pub const block_size = cloud.constants.block_size;
pub const frames = cloud.constants.cache_frames;

pub fn expectVecApprox(expected: cloud.Vec3d, actual: cloud.Vec3d, tolerance: f64) !void {
    inline for (0..cloud.constants.dims) |i| {
        try std.testing.expectApproxEqAbs(expected[i], actual[i], tolerance);
    }
}
