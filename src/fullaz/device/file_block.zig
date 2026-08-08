const std = @import("std");
const core = @import("../core/core.zig");
const errors = core.errors;

const Io = std.Io;

pub fn FileBlock(comptime BlockIdT: type) type {
    return struct {
        const Self = @This();
        pub const BlockId = BlockIdT;

        pub const Error = errors.PageError || errors.FileError;
        pub const Options = struct {
            start_position: usize = 0,
        };

        io: Io,
        file: Io.File,
        block_size: usize,
        block_count: usize,
        physical_blocks: usize,
        start_position: usize,
        is_open_flag: bool,

        pub fn create(io: Io, path: []const u8, block_size: usize) Error!Self {
            return createWithOptions(io, path, block_size, .{});
        }

        pub fn createWithOptions(io: Io, path: []const u8, block_size: usize, options: Options) Error!Self {
            if (block_size == 0) {
                return Error.BadData;
            }
            const start_position = std.math.cast(u64, options.start_position) orelse return Error.BadData;
            const file = Io.Dir.cwd().createFile(io, path, .{
                .read = true,
                .truncate = true,
            }) catch {
                return Error.CreateFailed;
            };
            errdefer file.close(io);
            file.setLength(io, start_position) catch {
                return Error.IoError;
            };
            return Self{
                .io = io,
                .file = file,
                .block_size = block_size,
                .block_count = 0,
                .physical_blocks = 0,
                .start_position = options.start_position,
                .is_open_flag = true,
            };
        }

        pub fn open(io: Io, path: []const u8, block_size: usize) Error!Self {
            return openWithOptions(io, path, block_size, .{});
        }

        pub fn openWithOptions(io: Io, path: []const u8, block_size: usize, options: Options) Error!Self {
            if (block_size == 0) {
                return Error.BadData;
            }
            const start_position = std.math.cast(u64, options.start_position) orelse return Error.BadData;
            const file = Io.Dir.cwd().openFile(io, path, .{
                .mode = .read_write,
            }) catch {
                return Error.OpenFailed;
            };
            errdefer file.close(io);
            const end = file.length(io) catch {
                return Error.IoError;
            };
            if (end < start_position) {
                return Error.BadData;
            }
            const block_size_u64 = std.math.cast(u64, block_size) orelse return Error.BadData;
            const region_length = end - start_position;
            if (region_length % block_size_u64 != 0) {
                return Error.BadData;
            }
            const blocks = std.math.cast(usize, region_length / block_size_u64) orelse return Error.BadData;
            return Self{
                .io = io,
                .file = file,
                .block_size = block_size,
                .block_count = blocks,
                .physical_blocks = blocks,
                .start_position = options.start_position,
                .is_open_flag = true,
            };
        }

        fn blockOffset(self: *const Self, idx: usize) Error!u64 {
            const idx_u64 = std.math.cast(u64, idx) orelse return Error.BadData;
            const block_size_u64 = std.math.cast(u64, self.block_size) orelse return Error.BadData;
            const start_position = std.math.cast(u64, self.start_position) orelse return Error.BadData;
            const relative = @mulWithOverflow(idx_u64, block_size_u64);
            if (relative[1] != 0) {
                return Error.BadData;
            }
            const offset = @addWithOverflow(start_position, relative[0]);
            if (offset[1] != 0) {
                return Error.BadData;
            }
            return offset[0];
        }

        fn blockEnd(self: *const Self, idx: usize) Error!u64 {
            const offset = try self.blockOffset(idx);
            const block_size_u64 = std.math.cast(u64, self.block_size) orelse return Error.BadData;
            const end = @addWithOverflow(offset, block_size_u64);
            if (end[1] != 0) {
                return Error.BadData;
            }
            return end[0];
        }

        pub fn deinit(self: *Self) void {
            if (self.is_open_flag) {
                self.file.close(self.io);
                self.is_open_flag = false;
            }
        }

        pub fn isValidId(self: *const Self, block_id: BlockId) bool {
            return @as(usize, @intCast(block_id)) < self.block_count;
        }

        pub fn isOpen(self: *const Self) bool {
            return self.is_open_flag;
        }

        pub fn blockSize(self: *const Self) usize {
            return self.block_size;
        }

        pub fn blocksCount(self: *const Self) usize {
            return self.block_count;
        }

        pub fn appendBlock(self: *Self) Error!BlockId {
            // Logical only: the file is not grown until the block is written.
            const new_id = self.block_count;
            self.block_count = new_id + 1;
            return @as(BlockId, @intCast(new_id));
        }

        pub fn truncateBlocks(self: *Self, count: usize) Error!void {
            if (count > self.block_count) {
                return Error.InvalidId;
            }
            const new_count = self.block_count - count;
            if (self.physical_blocks > new_count) {
                const new_length = try self.blockOffset(new_count);
                self.file.setLength(self.io, new_length) catch {
                    return Error.IoError;
                };
                self.physical_blocks = new_count;
            }
            self.block_count = new_count;
        }

        pub fn readBlock(self: *const Self, block_id: BlockId, output: []u8) Error!void {
            const idx = @as(usize, @intCast(block_id));
            if (idx >= self.block_count) {
                return Error.InvalidId;
            }
            const len = @min(output.len, self.block_size);
            if (idx >= self.physical_blocks) {
                @memset(output[0..len], 0);
                return;
            }
            const offset = try self.blockOffset(idx);
            _ = self.file.readPositionalAll(self.io, output[0..len], offset) catch {
                return Error.IoError;
            };
        }

        pub fn writeBlock(self: *Self, block_id: BlockId, output: []u8) Error!void {
            const idx = @as(usize, @intCast(block_id));
            if (idx >= self.block_count) {
                return Error.InvalidId;
            }
            if (idx >= self.physical_blocks) {
                const end = try self.blockEnd(idx);
                self.file.setLength(self.io, end) catch {
                    return Error.IoError;
                };
                self.physical_blocks = idx + 1;
            }
            const len = @min(output.len, self.block_size);
            const offset = try self.blockOffset(idx);
            self.file.writePositionalAll(self.io, output[0..len], offset) catch {
                return Error.IoError;
            };
        }

        pub fn sync(self: *Self) Error!void {
            self.file.sync(self.io) catch {
                return Error.IoError;
            };
        }
    };
}
