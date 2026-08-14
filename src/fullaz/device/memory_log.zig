const std = @import("std");

pub fn MemoryLog(comptime OffsetT: type) type {
    return struct {
        const Self = @This();
        pub const Error = std.mem.Allocator.Error || error{BadData};
        pub const Offset = OffsetT;

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
            const new_len = std.math.add(usize, self.buf.items.len, bytes.len) catch {
                return Error.BadData;
            };
            _ = std.math.cast(Offset, new_len) orelse return Error.BadData;
            try self.buf.appendSlice(self.allocator, bytes);
        }

        pub fn sync(self: *Self) Error!void {
            self.synced = std.math.cast(Offset, self.buf.items.len) orelse return Error.BadData;
        }

        pub fn reset(self: *Self) Error!void {
            self.buf.clearRetainingCapacity();
            self.synced = 0;
        }

        pub fn size(self: *const Self) Offset {
            return std.math.cast(Offset, self.buf.items.len) orelse unreachable;
        }

        pub fn readAt(self: *const Self, offset: Offset, dst: []u8) Error!void {
            const start = std.math.cast(usize, offset) orelse return Error.BadData;
            if (start > self.buf.items.len or dst.len > self.buf.items.len - start) {
                return Error.BadData;
            }
            @memcpy(dst, self.buf.items[start .. start + dst.len]);
        }
    };
}
