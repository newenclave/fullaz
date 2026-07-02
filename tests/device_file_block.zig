const std = @import("std");
const fullaz = @import("fullaz");
const device = fullaz.device;
const FileBlock = device.FileBlock;
const PageCacheT = fullaz.storage.page_cache.PageCache;

// Test images live under .zig-cache (gitignored, and always present during a
// build). 'prep' clears any leftover from a previous crashed run.
fn prep(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

test "FileBlock: satisfies the block-device contract + create/append/write/read" {
    comptime device.interfaces.assertBlockDevice(FileBlock(u32));

    const io = std.testing.io;
    const path = ".zig-cache/fb_contract.img";
    prep(io, path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const Dev = FileBlock(u32);
    var dev = try Dev.create(io, path, 64);
    defer dev.deinit();

    try std.testing.expect(dev.isOpen());
    try std.testing.expectEqual(@as(usize, 64), dev.blockSize());
    try std.testing.expectEqual(@as(usize, 0), dev.blocksCount());

    const b0 = try dev.appendBlock();
    const b1 = try dev.appendBlock();
    try std.testing.expectEqual(@as(u32, 0), b0);
    try std.testing.expectEqual(@as(u32, 1), b1);
    try std.testing.expectEqual(@as(usize, 2), dev.blocksCount());
    try std.testing.expect(dev.isValidId(b1));
    try std.testing.expect(!dev.isValidId(2));

    var wbuf: [64]u8 = undefined;
    @memset(&wbuf, 0xAB);
    try dev.writeBlock(b1, &wbuf);

    var rbuf: [64]u8 = .{0} ** 64;
    try dev.readBlock(b1, &rbuf);
    try std.testing.expectEqualSlices(u8, &wbuf, &rbuf);

    // block 0 is zero-filled (setLength zero-fills; we never wrote it)
    var zbuf: [64]u8 = undefined;
    @memset(&zbuf, 0xFF);
    try dev.readBlock(b0, &zbuf);
    try std.testing.expectEqualSlices(u8, &(.{0} ** 64), &zbuf);

    // out-of-range id -> InvalidId (from the device's own error set)
    try std.testing.expectError(Dev.Error.InvalidId, dev.readBlock(2, &rbuf));
    try std.testing.expectError(Dev.Error.InvalidId, dev.writeBlock(2, &wbuf));
}

test "FileBlock: data persists across deinit + reopen" {
    const io = std.testing.io;
    const path = ".zig-cache/fb_persist.img";
    prep(io, path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const Dev = FileBlock(u32);

    {
        var dev = try Dev.create(io, path, 128);
        defer dev.deinit();
        _ = try dev.appendBlock();
        _ = try dev.appendBlock();
        var buf: [128]u8 = undefined;
        @memset(&buf, 0x5C);
        try dev.writeBlock(1, &buf);
    }
    {
        var dev = try Dev.open(io, path, 128);
        defer dev.deinit();
        try std.testing.expectEqual(@as(usize, 2), dev.blocksCount());
        var buf: [128]u8 = .{0} ** 128;
        try dev.readBlock(1, &buf);
        try std.testing.expectEqualSlices(u8, &(.{0x5C} ** 128), &buf);
    }
}

test "FileBlock: PageCache round-trips a page to disk" {
    const io = std.testing.io;
    const path = ".zig-cache/fb_pagecache.img";
    prep(io, path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const Dev = FileBlock(u32);
    const PageCache = PageCacheT(Dev);

    var page_id: u32 = undefined;
    {
        var dev = try Dev.create(io, path, 256);
        defer dev.deinit();
        var cache = try PageCache.init(&dev, std.testing.allocator, 8);
        defer cache.deinit();
        var ph = try cache.create();
        defer ph.deinit();
        page_id = try ph.pid();
        const data = try ph.getDataMut();
        @memset(data, 0);
        @memcpy(data[0..5], "hello");
        try ph.markDirty();
    }
    {
        var dev = try Dev.open(io, path, 256);
        defer dev.deinit();
        var cache = try PageCache.init(&dev, std.testing.allocator, 8);
        defer cache.deinit();
        var ph = try cache.fetch(page_id);
        defer ph.deinit();
        const data = try ph.getData();
        try std.testing.expectEqualSlices(u8, "hello", data[0..5]);
    }
}
