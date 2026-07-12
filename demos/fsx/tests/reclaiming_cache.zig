const std = @import("std");
const fsx = @import("fsx");
const fullaz = @import("fullaz");

const ReclaimingCache = fsx.reclaiming_cache.ReclaimingCache;
const superblock = fsx.superblock;
const constants = fsx.constants;

const PageCacheT = fullaz.storage.page_cache.PageCache;
const MemoryBlock = fullaz.device.MemoryBlock;

const Device = MemoryBlock(u32);
const PageCache = PageCacheT(Device);
const RC = ReclaimingCache(PageCache);

fn formatSuperblock(cache: *PageCache) !void {
    var ph = try cache.create();
    defer ph.deinit();
    var sb = superblock.View(false).init(try ph.getDataMut());
    sb.format(4096);
    try cache.flush(constants.superblock_pid);
}

fn allocPid(rc: *RC) !u32 {
    var h = try rc.create();
    defer h.deinit();
    return try h.pid();
}

test "ReclaimingCache: create reuses freed pages LIFO; device stops growing" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 32);
    defer cache.deinit();

    try formatSuperblock(&cache);

    var rc = try RC.init(&cache);

    var p: [3]u32 = undefined;
    for (&p) |*pp| {
        pp.* = try allocPid(&rc);
    }
    const grown = device.blocksCount();

    try rc.free(p[1]);
    try rc.free(p[2]);

    try std.testing.expectEqual(p[2], try allocPid(&rc));
    try std.testing.expectEqual(p[1], try allocPid(&rc));
    try std.testing.expectEqual(grown, device.blocksCount());

    _ = try allocPid(&rc);
    try std.testing.expect(device.blocksCount() > grown);
}

test "ReclaimingCache: freed_head persists through the superblock across reopen" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 32);
    defer cache.deinit();

    try formatSuperblock(&cache);

    var freed: u32 = undefined;
    {
        var rc = try RC.init(&cache);
        const a = try allocPid(&rc);
        _ = try allocPid(&rc);
        try rc.free(a);
        freed = a;
    }

    {
        var rc = try RC.init(&cache);
        try std.testing.expectEqual(freed, try allocPid(&rc));
    }
}
