const std = @import("std");
const device = @import("fullaz").device;

test "Allocate and use device memory block" {
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

test "Write and read single block" {
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

test "Write and read multiple blocks" {
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

test "Read invalid block returns error" {
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

test "Write invalid block returns error" {
    const MemoryBlock = device.MemoryBlock(u32);
    const Error = MemoryBlock.Error;
    const block_size = 64;

    var mem_block = try MemoryBlock.init(std.testing.allocator, block_size);
    defer mem_block.deinit();

    var write_buf: [64]u8 = undefined;

    // Writing to empty storage should fail
    try std.testing.expectError(Error.InvalidId, mem_block.writeBlock(0, &write_buf));
}
