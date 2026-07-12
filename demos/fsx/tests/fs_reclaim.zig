const std = @import("std");
const fsx = @import("fsx");
const fullaz = @import("fullaz");

const fs = fsx.fs;

const PageCacheT = fullaz.storage.page_cache.PageCache;
const MemoryBlock = fullaz.device.MemoryBlock;

const Device = MemoryBlock(u32);
const PageCache = PageCacheT(Device);
const FsT = fs.Fs(PageCache, fsx.path.Default);

test "Fs rm reclaims a file's pages: device does not grow on recreate" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 64);
    defer cache.deinit();

    var f = try FsT.format(&cache, 4096);
    try f.mkdir("/a");

    const data = try allocator.alloc(u8, 12000);
    defer allocator.free(data);
    for (data, 0..) |*b, i| {
        b.* = @truncate(i * 13 + 5);
    }

    try f.touch("/a/big");
    _ = try f.write("/a/big", data);
    const after_first = device.blocksCount();

    try f.rm("/a/big");

    try f.touch("/a/big");
    _ = try f.write("/a/big", data);
    const after_second = device.blocksCount();

    try std.testing.expectEqual(after_first, after_second);

    const buf = try allocator.alloc(u8, 12000);
    defer allocator.free(buf);
    const r = try f.read("/a/big", buf);
    try std.testing.expectEqual(@as(usize, data.len), r);
    try std.testing.expectEqualSlices(u8, data, buf[0..r]);
}

test "Fs: repeated create/rm cycles keep the device bounded" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 64);
    defer cache.deinit();

    var f = try FsT.format(&cache, 4096);
    try f.mkdir("/d");

    const data = try allocator.alloc(u8, 9000);
    defer allocator.free(data);
    for (data, 0..) |*b, i| {
        b.* = @truncate(i);
    }

    try f.touch("/d/f");
    _ = try f.write("/d/f", data);
    const baseline = device.blocksCount();

    var cycle: usize = 0;
    while (cycle < 5) : (cycle += 1) {
        try f.rm("/d/f");
        try f.touch("/d/f");
        _ = try f.write("/d/f", data);
        try std.testing.expectEqual(baseline, device.blocksCount());
    }
}
