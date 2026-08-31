const std = @import("std");
const core = @import("../core/core.zig");
const errors = core.errors;

const Io = std.Io;

pub fn FileLog(comptime OffsetT: type) type {
    return struct {
        const Self = @This();
        pub const Error = errors.PageError || errors.FileError;
        pub const Offset = OffsetT;

        io: Io,
        file: Io.File,
        end: Offset,

        pub fn create(io: Io, path: []const u8) Error!Self {
            const file = Io.Dir.cwd().createFile(io, path, .{
                .read = true,
                .truncate = true,
            }) catch {
                return Error.CreateFailed;
            };
            return .{ .io = io, .file = file, .end = 0 };
        }

        pub fn open(io: Io, path: []const u8) Error!Self {
            const file = Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch {
                return Error.OpenFailed;
            };
            errdefer file.close(io);
            const len = file.length(io) catch {
                return Error.IoError;
            };
            return .{ .io = io, .file = file, .end = @intCast(len) };
        }

        pub fn deinit(self: *Self) void {
            self.file.close(self.io);
        }

        pub fn append(self: *Self, bytes: []const u8) Error!void {
            self.file.writePositionalAll(self.io, bytes, @intCast(self.end)) catch {
                return Error.IoError;
            };
            self.end += @as(Offset, @intCast(bytes.len));
        }

        pub fn sync(self: *Self) Error!void {
            self.file.sync(self.io) catch {
                return Error.IoError;
            };
        }

        pub fn reset(self: *Self) Error!void {
            try self.truncate(0);
        }

        /// Discards the suffix beginning at `end`.
        pub fn truncate(self: *Self, end: Offset) Error!void {
            if (end > self.end) {
                return Error.BadData;
            }
            self.file.setLength(self.io, @intCast(end)) catch {
                return Error.IoError;
            };
            self.end = end;
        }

        pub fn size(self: *const Self) Offset {
            return self.end;
        }

        pub fn readAt(self: *const Self, offset: Offset, dst: []u8) Error!void {
            const n = self.file.readPositionalAll(self.io, dst, @intCast(offset)) catch {
                return Error.IoError;
            };
            if (n != dst.len) {
                return Error.IoError;
            }
        }
    };
}
