const std = @import("std");

pub fn PackedInt(comptime T: type, comptime Endian: std.builtin.Endian) type {
    comptime {
        const ti = @typeInfo(T);
        if (ti != .int) {
            @compileError("WordT Supports only integer types; received " ++ @typeName(T));
        }
    }

    return extern struct {
        const Self = @This();

        pub const byte_count: usize = @sizeOf(T);
        pub const max = std.math.maxInt(T);
        pub const min = std.math.minInt(T);

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

        pub fn setMax(self: *Self) void {
            self.fromNative(std.math.maxInt(T));
        }

        pub fn isMax(self: *const Self) bool {
            return self.get() == std.math.maxInt(T);
        }

        pub fn isMaxVal(_: *const Self, val: T) bool {
            return val == std.math.maxInt(T);
        }

        pub fn setMin(self: *Self) void {
            self.fromNative(std.math.minInt(T));
        }

        pub fn isMin(self: *const Self) bool {
            return self.get() == std.math.minInt(T);
        }

        pub fn isMinVal(_: *const Self, val: T) bool {
            return val == std.math.minInt(T);
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

// IEEE-754 bit-preserving
pub fn PackedFloat(comptime T: type, comptime Endian: std.builtin.Endian) type {
    comptime {
        const ti = @typeInfo(T);
        if (ti != .float) {
            @compileError("PackedFloat supports only float types; received " ++ @typeName(T));
        }
    }

    const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));

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
            const bits = std.mem.readInt(Bits, &self.bytes, Endian);
            return @bitCast(bits);
        }

        pub fn fromNative(self: *Self, value: T) void {
            const bits: Bits = @bitCast(value);
            std.mem.writeInt(Bits, &self.bytes, bits, Endian);
        }

        pub fn get(self: *const Self) T {
            return self.toNative();
        }

        pub fn set(self: *Self, value: T) void {
            self.fromNative(value);
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

pub fn PackedNumber(comptime T: type, comptime Endian: std.builtin.Endian) type {
    return switch (@typeInfo(T)) {
        .int => PackedInt(T, Endian),
        .float => PackedFloat(T, Endian),
        else => @compileError("PackedNumber supports int and float types; received " ++ @typeName(T)),
    };
}

pub fn PackedIntLe(comptime T: type) type {
    return PackedInt(T, .little);
}

pub fn PackedIntBe(comptime T: type) type {
    return PackedInt(T, .big);
}
