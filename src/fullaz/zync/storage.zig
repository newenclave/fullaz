const std = @import("std");

/// Allocator-backed observer storage with no fixed subscriber limit.
pub const Dynamic = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Dynamic {
        return .{ .allocator = allocator };
    }

    pub fn Storage(comptime T: type) type {
        return struct {
            const Self = @This();

            pub const Error = std.mem.Allocator.Error;

            items: std.ArrayList(T) = .empty,
            allocator: std.mem.Allocator,

            pub fn init(policy: Dynamic) Self {
                return .{ .allocator = policy.allocator };
            }

            pub fn deinit(self: *Self) void {
                self.items.deinit(self.allocator);
                self.* = undefined;
            }

            pub fn append(self: *Self, value: T) Error!void {
                try self.items.append(self.allocator, value);
            }

            pub fn orderedRemove(self: *Self, index: usize) T {
                return self.items.orderedRemove(index);
            }

            pub fn slice(self: *const Self) []const T {
                return self.items.items;
            }

            pub fn clone(self: *const Self) Error!Self {
                var result = Self.init(.{ .allocator = self.allocator });
                errdefer result.deinit();
                try result.items.appendSlice(result.allocator, self.items.items);
                return result;
            }
        };
    }
};

/// Fixed-capacity observer storage embedded directly in its owner.
pub fn Fixed(comptime maximum_items: usize) type {
    comptime {
        if (maximum_items == 0) {
            @compileError("zync.Fixed requires at least one item");
        }
    }

    const Policy = struct {
        pub fn Storage(comptime T: type) type {
            return struct {
                const Self = @This();

                pub const Error = error{NotEnoughSpace};

                items: [maximum_items]T = undefined,
                len: usize = 0,

                pub fn init(_: anytype) Self {
                    return .{};
                }

                pub fn deinit(self: *Self) void {
                    self.* = undefined;
                }

                pub fn append(self: *Self, value: T) Error!void {
                    if (self.len == maximum_items) {
                        return error.NotEnoughSpace;
                    }
                    self.items[self.len] = value;
                    self.len += 1;
                }

                pub fn orderedRemove(self: *Self, index: usize) T {
                    const removed = self.items[index];
                    for (index..self.len - 1) |item_index| {
                        self.items[item_index] = self.items[item_index + 1];
                    }
                    self.len -= 1;
                    return removed;
                }

                pub fn slice(self: *const Self) []const T {
                    return self.items[0..self.len];
                }

                pub fn clone(self: *const Self) Error!Self {
                    var result = Self.init(.{});
                    @memcpy(result.items[0..self.len], self.items[0..self.len]);
                    result.len = self.len;
                    return result;
                }
            };
        }
    };
    return Policy;
}
