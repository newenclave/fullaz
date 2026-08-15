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

    // block 0 is zero-filled by the unwritten gap before block 1.
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

test "FileBlock: non-zero start position maps block zero after the prefix" {
    const io = std.testing.io;
    const path = ".zig-cache/fb_start_position.img";
    prep(io, path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const Dev = FileBlock(u32);
    const block_size = 16;
    const start_position = 21;
    const options: Dev.Options = .{ .start_position = start_position };
    var block0_data: [block_size]u8 = .{0xA0} ** block_size;
    var block1_data: [block_size]u8 = .{0xB1} ** block_size;

    {
        var dev = try Dev.createWithOptions(io, path, block_size, options);
        defer dev.deinit();

        try std.testing.expectEqual(@as(u64, start_position), try dev.file.length(io));

        var prefix: [start_position]u8 = .{0xEE} ** start_position;
        try dev.file.writePositionalAll(io, &prefix, 0);

        try std.testing.expectEqual(@as(u32, 0), try dev.appendBlock());
        try std.testing.expectEqual(@as(u32, 1), try dev.appendBlock());
        try dev.writeBlock(0, &block0_data);
        try dev.writeBlock(1, &block1_data);

        try std.testing.expectEqual(@as(u64, start_position + 2 * block_size), try dev.file.length(io));
        var raw: [start_position + 2 * block_size]u8 = undefined;
        _ = try dev.file.readPositionalAll(io, &raw, 0);
        try std.testing.expectEqualSlices(u8, &prefix, raw[0..start_position]);
        try std.testing.expectEqualSlices(u8, &block0_data, raw[start_position .. start_position + block_size]);
        try std.testing.expectEqualSlices(u8, &block1_data, raw[start_position + block_size ..]);
    }

    {
        var dev = try Dev.openWithOptions(io, path, block_size, options);
        defer dev.deinit();

        try std.testing.expectEqual(@as(usize, 2), dev.blocksCount());
        var output: [block_size]u8 = undefined;
        try dev.readBlock(0, &output);
        try std.testing.expectEqualSlices(u8, &block0_data, &output);
        try dev.readBlock(1, &output);
        try std.testing.expectEqualSlices(u8, &block1_data, &output);
    }
}

test "FileBlock: truncate preserves the prefix and shrinks to the region boundary" {
    const io = std.testing.io;
    const path = ".zig-cache/fb_start_truncate.img";
    prep(io, path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const Dev = FileBlock(u32);
    const block_size = 16;
    const start_position = 21;
    var dev = try Dev.createWithOptions(io, path, block_size, .{ .start_position = start_position });
    defer dev.deinit();

    var prefix: [start_position]u8 = .{0xEE} ** start_position;
    try dev.file.writePositionalAll(io, &prefix, 0);
    for (0..3) |_| {
        _ = try dev.appendBlock();
    }
    var block0: [block_size]u8 = .{0xA0} ** block_size;
    var block2: [block_size]u8 = .{0xC2} ** block_size;
    try dev.writeBlock(0, &block0);
    try dev.writeBlock(2, &block2);

    try dev.truncateBlocks(1);
    try std.testing.expectEqual(@as(usize, 2), dev.blocksCount());
    try std.testing.expectEqual(@as(u64, start_position + 2 * block_size), try dev.file.length(io));
    var retained: [start_position + 2 * block_size]u8 = undefined;
    _ = try dev.file.readPositionalAll(io, &retained, 0);
    try std.testing.expectEqualSlices(u8, &prefix, retained[0..start_position]);
    try std.testing.expectEqualSlices(u8, &block0, retained[start_position .. start_position + block_size]);

    try dev.truncateBlocks(2);
    try std.testing.expectEqual(@as(usize, 0), dev.blocksCount());
    try std.testing.expectEqual(@as(u64, start_position), try dev.file.length(io));
    var remaining_prefix: [start_position]u8 = undefined;
    _ = try dev.file.readPositionalAll(io, &remaining_prefix, 0);
    try std.testing.expectEqualSlices(u8, &prefix, &remaining_prefix);
}

test "FileBlock: truncating lazy blocks does not change the prefix" {
    const io = std.testing.io;
    const path = ".zig-cache/fb_start_lazy_truncate.img";
    prep(io, path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const Dev = FileBlock(u32);
    const start_position = 13;
    var dev = try Dev.createWithOptions(io, path, 16, .{ .start_position = start_position });
    defer dev.deinit();

    var prefix: [start_position]u8 = .{0xD3} ** start_position;
    try dev.file.writePositionalAll(io, &prefix, 0);
    for (0..3) |_| {
        _ = try dev.appendBlock();
    }
    try dev.truncateBlocks(3);

    try std.testing.expectEqual(@as(u64, start_position), try dev.file.length(io));
    var actual_prefix: [start_position]u8 = undefined;
    _ = try dev.file.readPositionalAll(io, &actual_prefix, 0);
    try std.testing.expectEqualSlices(u8, &prefix, &actual_prefix);
}

test "FileBlock: open with start position rejects an invalid region layout" {
    const io = std.testing.io;
    const path = ".zig-cache/fb_start_invalid_layout.img";
    prep(io, path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const Dev = FileBlock(u32);
    {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
        defer file.close(io);
        try file.setLength(io, 20);
    }
    try std.testing.expectError(Dev.Error.BadData, Dev.openWithOptions(io, path, 16, .{ .start_position = 21 }));

    {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        defer file.close(io);
        try file.setLength(io, 22);
    }
    try std.testing.expectError(Dev.Error.BadData, Dev.openWithOptions(io, path, 16, .{ .start_position = 21 }));
}

test "FileBlock: zero block size leaves an existing file unchanged" {
    const io = std.testing.io;
    const path = ".zig-cache/fb_zero_block_size.img";
    prep(io, path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const Dev = FileBlock(u32);
    {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
        defer file.close(io);
        var marker: [3]u8 = .{ 0xAB, 0xCD, 0xEF };
        try file.writePositionalAll(io, &marker, 0);
    }

    try std.testing.expectError(Dev.Error.BadData, Dev.createWithOptions(io, path, 0, .{ .start_position = 2 }));
    try std.testing.expectError(Dev.Error.BadData, Dev.openWithOptions(io, path, 0, .{}));

    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    var marker: [3]u8 = undefined;
    _ = try file.readPositionalAll(io, &marker, 0);
    try std.testing.expectEqualSlices(u8, &.{ 0xAB, 0xCD, 0xEF }, &marker);
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
        const data = try ph.dataMut();
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
        const data = try ph.data();
        try std.testing.expectEqualSlices(u8, "hello", data[0..5]);
    }
}

test "FileBlock: PageCache preserves a non-zero device prefix" {
    const io = std.testing.io;
    const path = ".zig-cache/fb_pagecache_start_position.img";
    prep(io, path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const Dev = FileBlock(u32);
    const PageCache = PageCacheT(Dev);
    const block_size = 64;
    const start_position = 13;
    const options: Dev.Options = .{ .start_position = start_position };
    var prefix: [start_position]u8 = .{0xD3} ** start_position;

    {
        var dev = try Dev.createWithOptions(io, path, block_size, options);
        defer dev.deinit();
        try dev.file.writePositionalAll(io, &prefix, 0);

        var cache = try PageCache.init(&dev, std.testing.allocator, 2);
        defer cache.deinit();
        var page = try cache.create();
        defer page.deinit();
        try std.testing.expectEqual(@as(u32, 0), try page.pid());
        @memcpy((try page.dataMut())[0..5], "hello");
        try cache.flushAll();

        var raw: [start_position + block_size]u8 = undefined;
        _ = try dev.file.readPositionalAll(io, &raw, 0);
        try std.testing.expectEqualSlices(u8, &prefix, raw[0..start_position]);
        try std.testing.expectEqualSlices(u8, "hello", raw[start_position .. start_position + 5]);
    }

    {
        var dev = try Dev.openWithOptions(io, path, block_size, options);
        defer dev.deinit();
        var cache = try PageCache.init(&dev, std.testing.allocator, 2);
        defer cache.deinit();
        var page = try cache.fetch(0);
        defer page.deinit();
        try std.testing.expectEqualSlices(u8, "hello", (try page.data())[0..5]);
    }
}

test "FileBlock: truncate blocks" {
    const io = std.testing.io;
    const path = ".zig-cache/fb_truncate.img";
    prep(io, path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const Dev = FileBlock(u32);

    var dev = try Dev.create(io, path, 64);
    defer dev.deinit();

    // Append 5 blocks
    for (0..5) |i| {
        _ = try dev.appendBlock();
        try std.testing.expectEqual(i + 1, dev.blocksCount());
    }

    // Truncate 2 blocks
    try dev.truncateBlocks(2);
    try std.testing.expectEqual(3, dev.blocksCount());

    var buf: [64]u8 = undefined;

    // Reading block 3 and 4 should fail
    try std.testing.expectError(Dev.Error.InvalidId, dev.readBlock(3, &buf));
    try std.testing.expectError(Dev.Error.InvalidId, dev.readBlock(4, &buf));

    // Writing to block 3 and 4 should fail
    try std.testing.expectError(Dev.Error.InvalidId, dev.writeBlock(3, &buf));
    try std.testing.expectError(Dev.Error.InvalidId, dev.writeBlock(4, &buf));
}

test "FileBlock: appendBlock is lazy, no physical growth until write" {
    const io = std.testing.io;
    const path = ".zig-cache/fb_lazy_append.img";
    prep(io, path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const Dev = FileBlock(u32);

    var dev = try Dev.create(io, path, 64);
    defer dev.deinit();

    _ = try dev.appendBlock();
    _ = try dev.appendBlock();
    _ = try dev.appendBlock();

    // Logical count grew, but the file on disk did not.
    try std.testing.expectEqual(@as(usize, 3), dev.blocksCount());
    try std.testing.expectEqual(@as(u64, 0), try dev.file.length(io));
}

test "FileBlock: reading an appended-but-unwritten block yields zeros" {
    const io = std.testing.io;
    const path = ".zig-cache/fb_lazy_read.img";
    prep(io, path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const Dev = FileBlock(u32);

    var dev = try Dev.create(io, path, 64);
    defer dev.deinit();

    _ = try dev.appendBlock();
    var buf: [64]u8 = undefined;
    @memset(&buf, 0xFF);
    try dev.readBlock(0, &buf);
    try std.testing.expectEqualSlices(u8, &(.{0} ** 64), &buf);
}

test "FileBlock: truncating purely-appended blocks never touches the file" {
    const io = std.testing.io;
    const path = ".zig-cache/fb_lazy_truncate.img";
    prep(io, path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const Dev = FileBlock(u32);

    var dev = try Dev.create(io, path, 64);
    defer dev.deinit();

    for (0..3) |_| {
        _ = try dev.appendBlock();
    }
    try std.testing.expectEqual(@as(u64, 0), try dev.file.length(io));

    // The discard path: rolling appends back is a pure in-memory reset.
    try dev.truncateBlocks(3);
    try std.testing.expectEqual(@as(usize, 0), dev.blocksCount());
    try std.testing.expectEqual(@as(u64, 0), try dev.file.length(io));
}

test "FileBlock: only physically-written blocks persist across reopen" {
    const io = std.testing.io;
    const path = ".zig-cache/fb_lazy_persist.img";
    prep(io, path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const Dev = FileBlock(u32);

    {
        var dev = try Dev.create(io, path, 64);
        defer dev.deinit();
        _ = try dev.appendBlock(); // block 0
        _ = try dev.appendBlock(); // block 1, appended but never written
        var buf: [64]u8 = undefined;
        @memset(&buf, 0x11);
        try dev.writeBlock(0, &buf);
    }
    {
        var dev = try Dev.open(io, path, 64);
        defer dev.deinit();
        // Only block 0 reached disk; the trailing unwritten append is gone.
        try std.testing.expectEqual(@as(usize, 1), dev.blocksCount());
    }
}
