const std = @import("std");
const core = @import("../core/core.zig");
const errors = core.errors;

pub fn MemoryBlock(comptime BlockIdT: type) type {
    return struct {
        const Self = @This();
        pub const BlockId = BlockIdT;

        pub const Error = errors.PageError || std.mem.Allocator.Error;
        pub const Options = struct {
            start_position: usize = 0,
        };

        allocator: std.mem.Allocator,
        block_size: usize,
        start_position: usize,
        storage: std.ArrayList(u8),

        pub fn init(allocator: std.mem.Allocator, block_size: usize) Error!Self {
            return initWithOptions(allocator, block_size, .{});
        }

        pub fn initWithOptions(allocator: std.mem.Allocator, block_size: usize, options: Options) Error!Self {
            if (block_size == 0) {
                return Error.BadData;
            }
            var storage = try std.ArrayList(u8).initCapacity(allocator, options.start_position);
            errdefer storage.deinit(allocator);
            try storage.resize(allocator, options.start_position);
            return Self{
                .allocator = allocator,
                .block_size = block_size,
                .start_position = options.start_position,
                .storage = storage,
            };
        }

        pub fn deinit(self: *Self) void {
            self.storage.deinit(self.allocator);
        }

        pub fn isValidId(self: *const Self, block_id: BlockId) bool {
            const idx = std.math.cast(usize, block_id) orelse return false;
            return idx < self.blocksCount();
        }

        pub fn isOpen(_: *const Self) bool {
            return true;
        }

        pub fn blockSize(self: *const Self) usize {
            return self.block_size;
        }

        pub fn blocksCount(self: *const Self) usize {
            return (self.storage.items.len - self.start_position) / self.block_size;
        }

        fn blockOffset(self: *const Self, idx: usize) Error!usize {
            const relative = @mulWithOverflow(idx, self.block_size);
            if (relative[1] != 0) {
                return Error.BadData;
            }
            const offset = @addWithOverflow(self.start_position, relative[0]);
            if (offset[1] != 0) {
                return Error.BadData;
            }
            return offset[0];
        }

        pub fn appendBlock(self: *Self) Error!BlockId {
            const block_id = std.math.cast(BlockId, self.blocksCount()) orelse return Error.InvalidId;
            const old_size = self.storage.items.len;
            const new_size = @addWithOverflow(old_size, self.block_size);
            if (new_size[1] != 0) {
                return Error.BadData;
            }
            try self.storage.resize(self.allocator, new_size[0]);
            return block_id;
        }

        pub fn truncateBlocks(self: *Self, count: usize) Error!void {
            const current_count = self.blocksCount();
            if (count > current_count) {
                return Error.InvalidId;
            }
            const new_count = current_count - count;
            const new_size = try self.blockOffset(new_count);
            try self.storage.resize(self.allocator, new_size);
        }

        pub fn readBlock(self: *const Self, block_id: BlockId, output: []u8) Error!void {
            const idx = std.math.cast(usize, block_id) orelse return Error.InvalidId;
            if (idx >= self.blocksCount()) {
                return Error.InvalidId;
            }
            const offset = try self.blockOffset(idx);
            const output_len = @min(output.len, self.block_size);
            const output_slice = output[0..output_len];
            const stored_slice = self.storage.items[offset .. offset + output_len];
            @memcpy(output_slice, stored_slice);
        }

        pub fn writeBlock(self: *Self, block_id: BlockId, output: []u8) Error!void {
            const idx = std.math.cast(usize, block_id) orelse return Error.InvalidId;
            if (idx >= self.blocksCount()) {
                return Error.InvalidId;
            }
            const offset = try self.blockOffset(idx);
            const output_len = @min(output.len, self.block_size);
            const output_slice = output[0..output_len];
            const stored_slice = self.storage.items[offset .. offset + output_len];
            @memcpy(stored_slice, output_slice);
        }

        pub fn sync(_: *Self) Error!void {
            // In-memory device: nothing to flush here
        }
    };
}
