const std = @import("std");
const errors = @import("../../core/errors.zig");
const PackedInt = @import("../../core/packed_int.zig").PackedInt;

pub fn IndexEntry(comptime PageIdT: type, comptime SizeT: type, comptime Endian: std.builtin.Endian) type {
    return extern struct {
        const PageId = PackedInt(PageIdT, Endian);
        const Size = PackedInt(SizeT, Endian);
        page_id: PageId,
        size: Size,
    };
}

pub fn IndexValuePolicy(comptime PageIdT: type, comptime SizeT: type, comptime Endian: std.builtin.Endian) type {
    return struct {
        const Entry = IndexEntry(PageIdT, SizeT, Endian);

        const Self = @This();

        pub const Error = errors.PageError;

        val: []const u8,

        pub fn init(ctx: anytype, val: []const u8) Self {
            _ = ctx;
            return .{ .val = val };
        }

        pub fn deinit(_: *Self) void {}

        pub fn weight(self: *const Self) Error!u32 {
            const entry: *const Entry = @ptrCast(self.val.ptr);
            return @as(u32, entry.size.get());
        }

        pub fn get(self: *const Self) Error![]const u8 {
            return self.val;
        }

        // --- never reached: inserts land on chunk boundaries (diff == 0) ---
        pub fn splitOfRight(_: *Self, _: u32) Error!Self {
            return Error.BadData;
        }

        pub fn splitOfLeft(_: *Self, _: u32) Error!Self {
            return Error.BadData;
        }

        pub fn expectedSplitDataFormat(_: *const Self, val: []const u8, pos: usize) struct { left: usize, right: usize } {
            return .{
                .left = pos,
                .right = val.len - pos,
            };
        }
    };
}
