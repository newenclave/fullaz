const std = @import("std");
const fsx = @import("fsx");
const fullaz = @import("fullaz");

const fs = fsx.fs;
const superblock = fsx.superblock;
const constants = fsx.constants;

const PageCacheT = fullaz.storage.page_cache.PageCache;
const MemoryBlock = fullaz.device.MemoryBlock;
const PageId = constants.PageId;

test "Fs: format then open validates; bad block size rejected" {
    const allocator = std.testing.allocator;
    const Device = MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const FsT = fs.Fs(PageCache, fsx.path.Default);

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 16);
    defer cache.deinit();

    var f = try FsT.format(&cache, 4096);
    try std.testing.expect((try f.getRootDirRoot()) == null);

    _ = try FsT.open(&cache, 4096);
    try std.testing.expectError(superblock.Error.BadBlockSize, FsT.open(&cache, 8192));
}

test "Fs: format requires a fresh device" {
    const allocator = std.testing.allocator;
    const Device = MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const FsT = fs.Fs(PageCache, fsx.path.Default);

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 16);
    defer cache.deinit();

    _ = try FsT.format(&cache, 4096);
    try std.testing.expectError(fs.Error.NotFreshDevice, FsT.format(&cache, 4096));
}

test "Fs: root dir root persists across a real reopen (new cache)" {
    const allocator = std.testing.allocator;
    const Device = MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const FsT = fs.Fs(PageCache, fsx.path.Default);

    var device = try Device.init(allocator, 4096);
    defer device.deinit();

    {
        var cache = try PageCache.init(&device, allocator, 16);
        defer cache.deinit();
        var f = try FsT.format(&cache, 4096);
        try f.setRootDirRoot(3);
    }

    {
        var cache = try PageCache.init(&device, allocator, 16);
        defer cache.deinit();
        var f = try FsT.open(&cache, 4096);
        try std.testing.expectEqual(@as(?PageId, 3), try f.getRootDirRoot());
    }
}
