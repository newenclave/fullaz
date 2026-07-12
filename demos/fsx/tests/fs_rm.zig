const std = @import("std");
const fsx = @import("fsx");
const fullaz = @import("fullaz");

const fs = fsx.fs;
const inode = fsx.inode;
const constants = fsx.constants;

const PageCacheT = fullaz.storage.page_cache.PageCache;
const MemoryBlock = fullaz.device.MemoryBlock;

const Device = MemoryBlock(u32);
const PageCache = PageCacheT(Device);
const FsT = fs.Fs(PageCache, fsx.path.Default);

test "Fs stat: reports kind and size" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 32);
    defer cache.deinit();

    var f = try FsT.format(&cache, 4096);
    try f.touch("/f");
    _ = try f.write("/f", "abcd");
    try f.mkdir("/d");

    const sf = try f.stat("/f");
    try std.testing.expectEqual(inode.Kind.file, sf.kind);
    try std.testing.expectEqual(@as(u32, 4), sf.size);

    const sd = try f.stat("/d");
    try std.testing.expectEqual(inode.Kind.dir, sd.kind);
    try std.testing.expectEqual(@as(u32, 0), sd.size);

    try std.testing.expectError(fs.Error.NotFound, f.stat("/nope"));
}

test "Fs rm: removes files and frees the name" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 32);
    defer cache.deinit();

    var f = try FsT.format(&cache, 4096);
    try f.touch("/f");
    try std.testing.expect((try f.resolve("/f")) != null);

    try f.rm("/f");
    try std.testing.expect((try f.resolve("/f")) == null);
    try std.testing.expectError(fs.Error.NotFound, f.rm("/f"));

    try f.mkdir("/d");
    try std.testing.expectError(fs.Error.IsADirectory, f.rm("/d"));

    try f.touch("/f");
    try std.testing.expect((try f.resolve("/f")) != null);

    try f.mkdir("/a");
    try f.touch("/a/g");
    try f.rm("/a/g");
    try std.testing.expect((try f.resolve("/a/g")) == null);
}

test "Fs rmdir: removes empty directories only" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 32);
    defer cache.deinit();

    var f = try FsT.format(&cache, 4096);

    try f.mkdir("/d");
    try f.rmdir("/d");
    try std.testing.expect((try f.resolve("/d")) == null);

    try f.mkdir("/a");
    try f.touch("/a/f");
    try std.testing.expectError(fs.Error.DirNotEmpty, f.rmdir("/a"));

    try f.rm("/a/f");
    try f.rmdir("/a");
    try std.testing.expect((try f.resolve("/a")) == null);

    try f.touch("/x");
    try std.testing.expectError(fs.Error.NotADirectory, f.rmdir("/x"));
    try std.testing.expectError(fs.Error.NotFound, f.rmdir("/nope"));
}

test "Fs rm/rmdir: persist across a real reopen" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();

    {
        var cache = try PageCache.init(&device, allocator, 32);
        defer cache.deinit();
        var f = try FsT.format(&cache, 4096);
        try f.mkdir("/a");
        try f.touch("/a/f");
        try f.mkdir("/a/sub");
        try f.rm("/a/f");
        try f.rmdir("/a/sub");
    }

    {
        var cache = try PageCache.init(&device, allocator, 32);
        defer cache.deinit();
        var f = try FsT.open(&cache, 4096);
        try std.testing.expect((try f.resolve("/a")) != null);
        try std.testing.expect((try f.resolve("/a/f")) == null);
        try std.testing.expect((try f.resolve("/a/sub")) == null);
    }
}
