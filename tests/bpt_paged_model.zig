const std = @import("std");
const algorithm = @import("fullaz").algorithm;
const bpt = @import("fullaz").bpt;
const PageCacheT = @import("fullaz").PageCache;
const dev = @import("fullaz").device;

test "Create a bpt" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const BptModel = bpt.models.PagedModel(PageCacheT(Device));

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();
    var model = BptModel.init(&cache);

    var tree = bpt.Bpt(BptModel).init(&model, .neighbor_share);
    defer tree.deinit();

    //tree.insert("hello", "world");
}
