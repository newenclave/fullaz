const std = @import("std");
const fullaz = @import("fullaz");
const common = @import("common.zig");

const cloud = common.cloud;
const constants = cloud.constants;
const superblock = cloud.superblock;
const ReclaimingCache = cloud.reclaiming_cache.ReclaimingCache;
const Device = common.Device;
const PageCache = common.PageCache;

fn formatSuperblock(cache: *PageCache) !void {
    var handle = try cache.create();
    defer handle.deinit();
    var view = superblock.View(false).init(try handle.dataMut());
    view.format(common.block_size, 1, 1);
}

fn createPage(cache: anytype) !u32 {
    var handle = try cache.create();
    defer handle.deinit();
    return try handle.pid();
}

test "cloud: reclaiming cache reuses and clears freed pages" {
    var device = try Device.init(std.testing.allocator, common.block_size);
    defer device.deinit();
    var cache = try PageCache.init(&device, std.testing.allocator, common.frames);
    defer cache.deinit();
    try formatSuperblock(&cache);

    const Cache = ReclaimingCache(PageCache);
    var reclaiming = Cache.init(&cache, .{});
    const first = try createPage(&reclaiming);
    const second = try createPage(&reclaiming);
    const blocks_before_reuse = device.blocksCount();

    {
        var handle = try cache.fetch(second);
        defer handle.deinit();
        @memset(try handle.dataMut(), 0xA5);
    }
    try reclaiming.free(first);
    try reclaiming.free(second);
    try std.testing.expectEqual(@as(usize, 2), reclaiming.state.free_page_count);

    const reused = try createPage(&reclaiming);
    try std.testing.expectEqual(second, reused);
    try std.testing.expectEqual(blocks_before_reuse, device.blocksCount());
    try std.testing.expectEqual(@as(usize, 1), reclaiming.state.free_page_count);
    try std.testing.expectEqual(@as(usize, 1), reclaiming.state.reused_page_count);
    {
        var handle = try cache.fetch(reused);
        defer handle.deinit();
        for (try handle.data()) |byte| {
            try std.testing.expectEqual(@as(u8, 0), byte);
        }
    }
}

test "cloud: reclaiming cache state persists in the superblock" {
    var device = try Device.init(std.testing.allocator, common.block_size);
    defer device.deinit();
    var cache = try PageCache.init(&device, std.testing.allocator, common.frames);
    defer cache.deinit();
    try formatSuperblock(&cache);

    const Cache = ReclaimingCache(PageCache);
    var reclaiming = Cache.init(&cache, .{});
    const page_id = try createPage(&reclaiming);
    try reclaiming.free(page_id);
    _ = try createPage(&reclaiming);

    var handle = try cache.fetch(constants.superblock_pid);
    defer handle.deinit();
    const view = superblock.View(true).init(try handle.data());
    try std.testing.expect((view.getFreePageRoot()) == null);
    try std.testing.expectEqual(@as(usize, 0), view.getFreePageCount());
    try std.testing.expectEqual(@as(usize, 1), view.getReusedPageCount());
}
