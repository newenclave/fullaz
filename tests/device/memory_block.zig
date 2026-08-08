const std = @import("std");
const fullaz = @import("fullaz");
const device = fullaz.device;
const PageCacheT = fullaz.storage.page_cache.PageCache;

test "DevMemBlock: Allocate and use device memory block" {
    const MemoryBlock = device.MemoryBlock;

    const allocator = std.testing.allocator;

    const block_size = 1024;
    var mem_block = try MemoryBlock(u32).init(allocator, block_size);
    defer mem_block.deinit();

    try std.testing.expect(mem_block.isOpen());
    try std.testing.expectEqual(block_size, mem_block.blockSize());
    try std.testing.expectEqual(0, mem_block.blocksCount());

    const block_id = try mem_block.appendBlock();
    try std.testing.expectEqual(0, @as(usize, @intCast(block_id)));
    try std.testing.expectEqual(1, mem_block.blocksCount());
}

test "DevMemBlock: Write and read single block" {
    const MemoryBlock = device.MemoryBlock;
    const block_size = 64;

    var mem_block = try MemoryBlock(u32).init(std.testing.allocator, block_size);
    defer mem_block.deinit();

    const block_id = try mem_block.appendBlock();

    // Write data to block
    var write_buf: [64]u8 = undefined;
    @memset(&write_buf, 0);
    @memcpy(write_buf[0..13], "Hello, World!");
    try mem_block.writeBlock(block_id, &write_buf);

    // Read data back
    var read_buf: [64]u8 = undefined;
    try mem_block.readBlock(block_id, &read_buf);

    try std.testing.expectEqualSlices(u8, &write_buf, &read_buf);
    try std.testing.expectEqualStrings("Hello, World!", read_buf[0..13]);
}

test "DevMemBlock: Write and read multiple blocks" {
    const MemoryBlock = device.MemoryBlock;
    const block_size = 32;

    var mem_block = try MemoryBlock(u32).init(std.testing.allocator, block_size);
    defer mem_block.deinit();

    // Append multiple blocks
    const block0 = try mem_block.appendBlock();
    const block1 = try mem_block.appendBlock();
    const block2 = try mem_block.appendBlock();

    try std.testing.expectEqual(3, mem_block.blocksCount());

    // Write different data to each block
    var buf0: [32]u8 = undefined;
    var buf1: [32]u8 = undefined;
    var buf2: [32]u8 = undefined;

    @memset(&buf0, 'A');
    @memset(&buf1, 'B');
    @memset(&buf2, 'C');

    try mem_block.writeBlock(block0, &buf0);
    try mem_block.writeBlock(block1, &buf1);
    try mem_block.writeBlock(block2, &buf2);

    // Read back and verify each block has correct data
    var read_buf: [32]u8 = undefined;

    try mem_block.readBlock(block0, &read_buf);
    try std.testing.expectEqual(@as(u8, 'A'), read_buf[0]);
    try std.testing.expectEqual(@as(u8, 'A'), read_buf[31]);

    try mem_block.readBlock(block1, &read_buf);
    try std.testing.expectEqual(@as(u8, 'B'), read_buf[0]);
    try std.testing.expectEqual(@as(u8, 'B'), read_buf[31]);

    try mem_block.readBlock(block2, &read_buf);
    try std.testing.expectEqual(@as(u8, 'C'), read_buf[0]);
    try std.testing.expectEqual(@as(u8, 'C'), read_buf[31]);
}

test "DevMemBlock: Read invalid block returns error" {
    const MemoryBlock = device.MemoryBlock(u32);
    const Error = MemoryBlock.Error;
    const block_size = 64;

    var mem_block = try MemoryBlock.init(std.testing.allocator, block_size);
    defer mem_block.deinit();

    var read_buf: [64]u8 = undefined;

    // Reading from empty storage should fail
    try std.testing.expectError(Error.InvalidId, mem_block.readBlock(0, &read_buf));

    // Append one block
    _ = try mem_block.appendBlock();

    // Reading block 1 (doesn't exist) should fail
    try std.testing.expectError(Error.InvalidId, mem_block.readBlock(1, &read_buf));
}

test "DevMemBlock: Write invalid block returns error" {
    const MemoryBlock = device.MemoryBlock(u32);
    const Error = MemoryBlock.Error;
    const block_size = 64;

    var mem_block = try MemoryBlock.init(std.testing.allocator, block_size);
    defer mem_block.deinit();

    var write_buf: [64]u8 = undefined;

    // Writing to empty storage should fail
    try std.testing.expectError(Error.InvalidId, mem_block.writeBlock(0, &write_buf));
}

test "DevMemBlock: truncate blocks reduces count and invalidates removed blocks" {
    const MemoryBlock = device.MemoryBlock(u32);
    const Error = MemoryBlock.Error;
    const block_size = 64;

    var mem_block = try MemoryBlock.init(std.testing.allocator, block_size);
    defer mem_block.deinit();

    // Append 5 blocks
    for (0..5) |i| {
        _ = try mem_block.appendBlock();
        try std.testing.expectEqual(i + 1, mem_block.blocksCount());
    }

    // Truncate 2 blocks
    try mem_block.truncateBlocks(2);
    try std.testing.expectEqual(3, mem_block.blocksCount());

    var buf: [64]u8 = undefined;

    // Reading block 3 and 4 should fail
    try std.testing.expectError(Error.InvalidId, mem_block.readBlock(3, &buf));
    try std.testing.expectError(Error.InvalidId, mem_block.readBlock(4, &buf));

    // Writing to block 3 and 4 should fail
    try std.testing.expectError(Error.InvalidId, mem_block.writeBlock(3, &buf));
    try std.testing.expectError(Error.InvalidId, mem_block.writeBlock(4, &buf));
}

test "DevMemBlock: non-zero start position isolates the prefix" {
    const MemoryBlock = device.MemoryBlock(u32);
    comptime device.interfaces.assertBlockDevice(MemoryBlock);

    const block_size = 16;
    const start_position = 13;
    var mem_block = try MemoryBlock.initWithOptions(std.testing.allocator, block_size, .{
        .start_position = start_position,
    });
    defer mem_block.deinit();

    try std.testing.expectEqual(@as(usize, 0), mem_block.blocksCount());
    try std.testing.expectEqual(@as(usize, start_position), mem_block.storage.items.len);
    @memset(mem_block.storage.items, 0xD3);

    const block0 = try mem_block.appendBlock();
    const block1 = try mem_block.appendBlock();
    try std.testing.expectEqual(@as(u32, 0), block0);
    try std.testing.expectEqual(@as(u32, 1), block1);
    try std.testing.expect(mem_block.isValidId(block0));
    try std.testing.expect(mem_block.isValidId(block1));
    try std.testing.expectEqual(@as(usize, 2), mem_block.blocksCount());

    var block0_data: [block_size]u8 = .{0xA0} ** block_size;
    var block1_data: [block_size]u8 = .{0xB1} ** block_size;
    try mem_block.writeBlock(block0, &block0_data);
    try mem_block.writeBlock(block1, &block1_data);

    try std.testing.expectEqual(@as(usize, start_position + 2 * block_size), mem_block.storage.items.len);
    try std.testing.expectEqualSlices(u8, &(.{0xD3} ** start_position), mem_block.storage.items[0..start_position]);
    try std.testing.expectEqualSlices(u8, &block0_data, mem_block.storage.items[start_position .. start_position + block_size]);
    try std.testing.expectEqualSlices(u8, &block1_data, mem_block.storage.items[start_position + block_size ..]);

    var output: [block_size]u8 = undefined;
    try mem_block.readBlock(block0, &output);
    try std.testing.expectEqualSlices(u8, &block0_data, &output);
    try mem_block.readBlock(block1, &output);
    try std.testing.expectEqualSlices(u8, &block1_data, &output);

    try mem_block.truncateBlocks(1);
    try std.testing.expectEqual(@as(usize, 1), mem_block.blocksCount());
    try std.testing.expectEqual(@as(usize, start_position + block_size), mem_block.storage.items.len);
    try std.testing.expectError(MemoryBlock.Error.InvalidId, mem_block.readBlock(block1, &output));
    try std.testing.expectEqualSlices(u8, &(.{0xD3} ** start_position), mem_block.storage.items[0..start_position]);

    try mem_block.truncateBlocks(1);
    try std.testing.expectEqual(@as(usize, 0), mem_block.blocksCount());
    try std.testing.expectEqual(@as(usize, start_position), mem_block.storage.items.len);
    try std.testing.expectEqualSlices(u8, &(.{0xD3} ** start_position), mem_block.storage.items);
}

test "DevMemBlock: zero block size is rejected" {
    const MemoryBlock = device.MemoryBlock(u32);
    try std.testing.expectError(MemoryBlock.Error.BadData, MemoryBlock.initWithOptions(std.testing.allocator, 0, .{
        .start_position = 13,
    }));
}

test "DevMemBlock: PageCache preserves a non-zero device prefix" {
    const MemoryBlock = device.MemoryBlock(u32);
    const PageCache = PageCacheT(MemoryBlock);
    const block_size = 64;
    const start_position = 13;
    var mem_block = try MemoryBlock.initWithOptions(std.testing.allocator, block_size, .{
        .start_position = start_position,
    });
    defer mem_block.deinit();
    @memset(mem_block.storage.items, 0xD3);

    var cache = try PageCache.init(&mem_block, std.testing.allocator, 2);
    defer cache.deinit();
    var page = try cache.create();
    defer page.deinit();
    try std.testing.expectEqual(@as(u32, 0), try page.pid());
    @memcpy((try page.getDataMut())[0..5], "hello");
    try cache.flushAll();

    try std.testing.expectEqualSlices(u8, &(.{0xD3} ** start_position), mem_block.storage.items[0..start_position]);
    try std.testing.expectEqualSlices(u8, "hello", mem_block.storage.items[start_position .. start_position + 5]);
}
