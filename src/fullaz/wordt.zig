const std = @import("std");

pub fn WordT(comptime T: type, comptime Endian: std.builtin.Endian) type {
    comptime {
        const ti = @typeInfo(T);
        if (ti != .int) {
            @compileError("WordT Supports only integer types; received " ++ @typeName(T));
        }
    }

    return extern struct {
        const Self = @This();
        pub const byte_count: usize = @sizeOf(T);

        bytes: [byte_count]u8,

        pub fn init(value: T) Self {
            var self: Self = .{ .bytes = std.mem.zeroes([byte_count]u8) };
            self.fromNative(value);
            return self;
        }

        pub fn toNative(self: *const Self) T {
            return std.mem.readInt(T, &self.bytes, Endian);
        }

        pub fn fromNative(self: *Self, value: T) void {
            std.mem.writeInt(T, &self.bytes, value, Endian);
        }

        pub fn get(self: *const Self) T {
            return self.toNative();
        }

        pub fn set(self: *Self, value: T) void {
            self.fromNative(value);
        }

        pub fn max() T {
            return std.math.maxInt(T);
        }

        pub fn min() T {
            return std.math.minInt(T);
        }

        pub fn fromBytes(bytes: [byte_count]u8) Self {
            return .{ .bytes = bytes };
        }

        pub fn fromSlice(src: []const u8) !Self {
            if (src.len < byte_count) {
                return error.BufferTooSmall;
            }
            var self: Self = undefined;
            @memcpy(self.bytes[0..], src[0..byte_count]);
            return self;
        }

        pub fn writeTo(self: *const Self, dst: []u8) !void {
            if (dst.len < byte_count) {
                return error.BufferTooSmall;
            }
            @memcpy(dst[0..byte_count], self.bytes[0..]);
        }
    };
}

pub fn WordLe(comptime T: type) type {
    return WordT(T, .little);
}

pub fn WordBe(comptime T: type) type {
    return WordT(T, .big);
}
