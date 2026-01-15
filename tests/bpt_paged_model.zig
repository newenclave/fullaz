const std = @import("std");
const algorithm = @import("fullaz").algorithm;
const bpt = @import("fullaz").bpt;
const PageCacheT = @import("fullaz").PageCache;
const dev = @import("fullaz").device;

test "Create a bpt" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const BptModel = bpt.models.PagedModel(PageCacheT(Device), .{});

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();
    var model = BptModel.init(&cache);

    var tree = bpt.Bpt(BptModel).init(&model, .neighbor_share);
    defer tree.deinit();

    //tree.insert("hello", "world");
}

test "test models functionality" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const BptModel = bpt.models.PagedModel(PageCacheT(Device), .{});
    var device = try Device.init(allocator, 4096);

    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();
    var model = BptModel.init(&cache);

    var accessor = model.getAccessor();
    const available_before = cache.availableFrames();

    var leaf = try accessor.createLeaf();
    const leaf_load = try accessor.loadLeaf(try leaf.handle.pid());
    const leaf_taken = try leaf.take();
    accessor.deinitLeaf(leaf);
    accessor.deinitLeaf(leaf_taken);
    accessor.deinitLeaf(leaf_load);

    try std.testing.expect((try leaf_taken.size()) == 0);

    var inode = try accessor.createInode();
    const inode_load = try accessor.loadInode(try inode.handle.pid());
    const inode_taken = try inode.take();
    accessor.deinitInode(inode);
    accessor.deinitInode(inode_load);
    accessor.deinitInode(inode_taken);

    //std.testing.expect(inode_taken.size() == 0);

    const available_after = cache.availableFrames();
    try std.testing.expect(available_before == available_after);
}
