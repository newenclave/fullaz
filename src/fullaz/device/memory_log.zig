const std = @import("std");
const core = @import("../core/core.zig");
const errors = core.errors;

const Io = std.Io;

pub const MemoryLog = struct {
    const Self = @This();
    pub const Error = std.mem.Allocator.Error;
    pub const Offset = usize;

    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8),
    synced: Offset,

    pub fn init(allocator: std.mem.Allocator) Error!Self {
        return .{
            .allocator = allocator,
            .buf = try std.ArrayList(u8).initCapacity(allocator, 0),
            .synced = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buf.deinit(self.allocator);
    }

    pub fn append(self: *Self, bytes: []const u8) Error!void {
        try self.buf.appendSlice(self.allocator, bytes);
    }

    pub fn sync(self: *Self) Error!void {
        self.synced = self.buf.items.len;
    }

    pub fn reset(self: *Self) Error!void {
        self.buf.clearRetainingCapacity();
        self.synced = 0;
    }

    pub fn size(self: *const Self) Offset {
        return self.buf.items.len;
    }

    pub fn readAt(self: *const Self, offset: Offset, dst: []u8) Error!void {
        @memcpy(dst, self.buf.items[offset .. offset + dst.len]);
    }
};
