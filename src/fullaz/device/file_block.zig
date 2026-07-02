const std = @import("std");
const core = @import("../core/core.zig");
const errors = core.errors;

const Io = std.Io;

pub fn FileBlock(comptime BlockIdT: type) type {
    return struct {
        const Self = @This();
        pub const BlockId = BlockIdT;

        pub const Error = errors.PageError || errors.FileError;

        io: Io,
        file: Io.File,
        block_size: usize,
        block_count: usize,
        is_open_flag: bool,

        pub fn create(io: Io, path: []const u8, block_size: usize) Error!Self {
            const file = Io.Dir.cwd().createFile(io, path, .{
                .read = true,
                .truncate = true,
            }) catch return Error.CreateFailed;
            return Self{
                .io = io,
                .file = file,
                .block_size = block_size,
                .block_count = 0,
                .is_open_flag = true,
            };
        }

        pub fn open(io: Io, path: []const u8, block_size: usize) Error!Self {
            const file = Io.Dir.cwd().openFile(io, path, .{
                .mode = .read_write,
            }) catch return Error.OpenFailed;
            errdefer file.close(io);
            const end = file.length(io) catch return Error.IoError;
            return Self{
                .io = io,
                .file = file,
                .block_size = block_size,
                .block_count = @as(usize, @intCast(end)) / block_size,
                .is_open_flag = true,
            };
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
            const new_id = self.block_count;
            const new_len = (new_id + 1) * self.block_size;
            self.file.setLength(self.io, @as(u64, @intCast(new_len))) catch return Error.IoError;
            self.block_count = new_id + 1;
            return @as(BlockId, @intCast(new_id));
        }

        pub fn readBlock(self: *const Self, block_id: BlockId, output: []u8) Error!void {
            const idx = @as(usize, @intCast(block_id));
            if (idx >= self.block_count) {
                return Error.InvalidId;
            }
            const len = @min(output.len, self.block_size);
            const offset = @as(u64, @intCast(idx * self.block_size));
            _ = self.file.readPositionalAll(self.io, output[0..len], offset) catch return Error.IoError;
        }

        pub fn writeBlock(self: *Self, block_id: BlockId, output: []u8) Error!void {
            const idx = @as(usize, @intCast(block_id));
            if (idx >= self.block_count) {
                return Error.InvalidId;
            }
            const len = @min(output.len, self.block_size);
            const offset = @as(u64, @intCast(idx * self.block_size));
            self.file.writePositionalAll(self.io, output[0..len], offset) catch return Error.IoError;
        }
    };
}
