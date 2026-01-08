const std = @import("std");

pub fn MemoryBlock(comptime BlockIdT: type) type {
    return struct {
        const Self = @This();
        pub const BlockId = BlockIdT;

        allocator: std.mem.Allocator,
        block_size: usize,
        storage: std.ArrayList(u8),

        pub fn init(allocator: std.mem.Allocator, block_size: usize) !Self {
            return Self{
                .allocator = allocator,
                .block_size = block_size,
                .storage = try std.ArrayList(u8).initCapacity(allocator, 0),
            };
        }

        pub fn deinit(self: *Self) void {
            self.storage.deinit(self.allocator);
        }

        pub fn isValidId(self: *const Self, block_id: BlockId) bool {
            const offset = @as(usize, @intCast(block_id)) * self.block_size;
            return (offset + self.block_size) <= self.storage.items.len;
        }

        pub fn isOpen(_: *const Self) bool {
            return true;
        }

        pub fn blockSize(self: *const Self) usize {
            return self.block_size;
        }

        pub fn blocksCount(self: *const Self) usize {
            return self.storage.items.len / self.block_size;
        }

        pub fn appendBlock(self: *Self) anyerror!BlockId {
            const old_size = self.storage.items.len;
            try self.storage.resize(self.allocator, old_size + self.block_size);
            return @as(BlockId, @intCast(old_size / self.block_size));
        }

        pub fn readBlock(self: *const Self, block_id: BlockId, output: []u8) anyerror!void {
            const offset = @as(usize, @intCast(block_id)) * self.block_size;
            if (offset + self.block_size > self.storage.items.len) {
                return error.InvalidBlockId;
            }
            const output_len = @min(output.len, self.block_size);
            const output_slice = output[0..output_len];
            const stored_slice = self.storage.items[offset .. offset + output_len];
            @memcpy(output_slice, stored_slice);
        }

        pub fn writeBlock(self: *const Self, block_id: BlockId, output: []u8) anyerror!void {
            const offset: usize = @as(usize, @intCast(block_id)) * self.block_size;
            if (offset + self.block_size > self.storage.items.len) {
                return error.InvalidBlockId;
            }
            const output_len = @min(output.len, self.block_size);
            const output_slice = output[0..output_len];
            const stored_slice = self.storage.items[offset .. offset + output_len];
            @memcpy(stored_slice, output_slice);
        }
    };
}
