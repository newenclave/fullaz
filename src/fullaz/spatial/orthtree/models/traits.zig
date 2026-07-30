const std = @import("std");

const BoundingBox = @import("../../geometry.zig").BoundingBox;

pub fn Empty(comptime T: type, comptime dimention: usize, comptime ValueT: type) type {
    return struct {
        const Self = @This();
        pub const Error = error{};
        pub const EntryData = void;
        pub const Box = BoundingBox(T, dimention);
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
