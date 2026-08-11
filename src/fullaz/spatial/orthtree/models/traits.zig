const std = @import("std");

const BoundingBox = @import("../../geometry.zig").BoundingBox;

pub fn Empty(comptime CoordT: type, comptime dimention: usize, comptime ValueT: type) type {
    return struct {
        const Self = @This();
        pub const Error = error{};
        pub const EntryData = void;
        pub const Box = BoundingBox(CoordT, dimention);
        pub const Value = ValueT;

        pub fn init() Self {
            return .{};
        }

        pub fn onInsert(self: *Self, box: Box, value: ValueT) Self.Error!void {
            _ = self;
            _ = box;
            _ = value;
        }

        pub fn onGrow(self: *Self, old: *const Self) Self.Error!void {
            _ = self;
            _ = old;
        }

        pub fn onAdopt(self: *Self, box: Box, value: ValueT) Self.Error!void {
            _ = self;
            _ = box;
            _ = value;
        }

        pub fn onRemove(self: *Self, box: Box, value: ValueT) Self.Error!void {
            _ = self;
            _ = box;
            _ = value;
        }
    };
}

pub fn PagedEmpty(comptime CoordT: type, comptime dimention: usize, comptime ValueT: type) type {
    return struct {
        pub const Storage = extern struct {
            reserved: [1]u8,
        };
        pub const Error = error{};
        pub const Box = BoundingBox(CoordT, dimention);
        pub const Value = ValueT;

        pub fn format(storage: *Storage) void {
            storage.reserved[0] = 0;
        }

        pub fn validate(storage: *const Storage) bool {
            return storage.reserved[0] == 0;
        }

        pub fn onInsert(_: *Storage, _: Box, _: []const u8) Error!void {}
        pub fn onGrow(_: *Storage, _: *const Storage) Error!void {}
        pub fn onAdopt(_: *Storage, _: Box, _: []const u8) Error!void {}
        pub fn onRemove(_: *Storage, _: Box, _: []const u8) Error!void {}
    };
}
