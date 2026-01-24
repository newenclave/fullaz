const std = @import("std");

const errors = @import("fullaz").errors;

const fullaz = @import("fullaz");
const PackedInt = fullaz.core.packed_int.PackedInt;
const PackedIntLe = fullaz.core.packed_int.PackedIntLe;
const PackedIntBe = fullaz.core.packed_int.PackedIntBe;

// ---------------------------------------------
// A "view" wrapper for mapping onto a buffer.
// Immutable + mutable variants.
// ---------------------------------------------
fn WordViewConst(comptime T: type, comptime Endian: std.builtin.Endian) type {
    comptime {
        switch (@typeInfo(T)) {
            .int => {},
            else => @compileError("WordViewConst supports only integer types; got " ++ @typeName(T)),
        }
    }

    return struct {
        const Self = @This();
        pub const byte_count: usize = @sizeOf(T);

        bytes: []const u8,

        pub fn init(src: []const u8) !Self {
            if (src.len < byte_count) {
                return error.BufferTooSmall;
            }
            return .{ .bytes = src[0..byte_count] };
        }

        pub fn get(self: *const Self) T {
            var tmp: [byte_count]u8 = undefined;
            @memcpy(tmp[0..], self.bytes[0..]);
            return std.mem.readInt(T, &tmp, Endian);
        }
    };
}

fn WordViewMut(comptime T: type, comptime Endian: std.builtin.Endian) type {
    comptime {
        switch (@typeInfo(T)) {
            .int => {},
            else => @compileError("WordViewMut supports only integer types; got " ++ @typeName(T)),
        }
    }

    return struct {
        const Self = @This();
        pub const byte_count: usize = @sizeOf(T);

        bytes: []u8,

        pub fn init(dst: []u8) !Self {
            if (dst.len < byte_count) {
                return error.BufferTooSmall;
            }
            return .{ .bytes = dst[0..byte_count] };
        }

        pub fn get(self: *const Self) T {
            var tmp: [byte_count]u8 = undefined;
            @memcpy(tmp[0..], self.bytes[0..]);
            return std.mem.readInt(T, &tmp, Endian);
        }

        pub fn set(self: *Self, value: T) void {
            var tmp: [byte_count]u8 = undefined;
            std.mem.writeInt(T, &tmp, value, Endian);
            @memcpy(self.bytes[0..], tmp[0..]);
        }
    };
}

// ---------------------------------------------
// Helpers
// ---------------------------------------------
fn expectBytesEqual(expected: []const u8, actual: []const u8) !void {
    try std.testing.expectEqual(@as(usize, expected.len), actual.len);
    try std.testing.expectEqualSlices(u8, expected, actual);
}

// ---------------------------------------------
// Tests: standalone WordT
// ---------------------------------------------
test "WordT: init/get/set roundtrip (u16 LE)" {
    var w = PackedIntLe(u16).init(0x1234);
    try std.testing.expectEqual(@as(u16, 0x1234), w.get());

    w.set(0xABCD);
    try std.testing.expectEqual(@as(u16, 0xABCD), w.get());

    // LE should store low byte first: 0xCD 0xAB
    try expectBytesEqual(&[_]u8{ 0xCD, 0xAB }, w.bytes[0..]);
}

test "WordT: init/get/set roundtrip (u16 BE)" {
    var w = PackedIntBe(u16).init(0x1234);
    try std.testing.expectEqual(@as(u16, 0x1234), w.get());

    w.set(0xABCD);
    try std.testing.expectEqual(@as(u16, 0xABCD), w.get());

    // BE should store high byte first: 0xAB 0xCD
    try expectBytesEqual(&[_]u8{ 0xAB, 0xCD }, w.bytes[0..]);
}

test "WordT: fromBytes works" {
    const W = PackedIntLe(u32);

    const raw: [4]u8 = .{ 0x78, 0x56, 0x34, 0x12 }; // 0x12345678 LE
    const w = W.fromBytes(raw);

    try std.testing.expectEqual(@as(u32, 0x12345678), w.get());
    try expectBytesEqual(raw[0..], w.bytes[0..]);
}

test "WordT: fromSlice success and error" {
    const W = PackedIntBe(u32);

    const ok_src: []const u8 = &[_]u8{ 0x12, 0x34, 0x56, 0x78, 0xAA };
    const w_ok = try W.fromSlice(ok_src);
    try std.testing.expectEqual(@as(u32, 0x12345678), w_ok.get());

    const bad_src: []const u8 = &[_]u8{ 0x12, 0x34, 0x56 };
    try std.testing.expectError(error.BufferTooSmall, W.fromSlice(bad_src));
}

test "WordT: writeTo success and error" {
    const W = PackedIntLe(u64);

    const w = W.init(0x1122334455667788);

    var dst_ok: [8]u8 = undefined;
    try w.writeTo(dst_ok[0..]);
    // LE: 88 77 66 55 44 33 22 11
    try expectBytesEqual(&[_]u8{ 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11 }, dst_ok[0..]);

    var dst_bad: [7]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, w.writeTo(dst_bad[0..]));
}

test "PackedInt: u128 check" {
    const W = PackedIntLe(u128);

    const w = W.init(0x1122334455667788_1122334455667788);

    var dst_ok: [16]u8 = undefined;
    try w.writeTo(dst_ok[0..]);
    // LE: 88 77 66 55 44 33 22 11
    // zig fmt: off
    try expectBytesEqual(&[_]u8{ 
        0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 
        0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
    }, dst_ok[0..]);
    // zig fmt: on

    var dst_bad: [7]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, w.writeTo(dst_bad[0..]));
}

test "WordT: min/max sanity for signed and unsigned" {
    try std.testing.expectEqual(std.math.maxInt(u16), PackedIntLe(u16).max);
    try std.testing.expectEqual(std.math.minInt(u16), PackedIntLe(u16).min);

    try std.testing.expectEqual(std.math.maxInt(i32), PackedIntBe(i32).max);
    try std.testing.expectEqual(std.math.minInt(i32), PackedIntBe(i32).min);
}

test "WordT: randomized roundtrip for multiple types/endians" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rnd = prng.random();

    inline for (.{ u16, u32, u64, i16, i32, i64 }) |T| {
        inline for (.{ std.builtin.Endian.little, std.builtin.Endian.big }) |E| {
            const W = PackedInt(T, E);

            var i: usize = 0;
            while (i < 200) : (i += 1) {
                // Generate arbitrary bits, then bitcast into T.
                const U = std.meta.Int(.unsigned, @bitSizeOf(T));
                const bits: U = rnd.int(U);
                const val: T = @bitCast(bits);

                var w = W.init(val);
                try std.testing.expectEqual(val, w.get());

                // Write to buffer and read back via fromSlice
                var buf: [@sizeOf(T)]u8 = undefined;
                try w.writeTo(buf[0..]);

                const w2 = try W.fromSlice(buf[0..]);
                try std.testing.expectEqual(val, w2.get());
            }
        }
    }
}

// ---------------------------------------------
// Tests: mapping/view onto external slices
// ---------------------------------------------
test "WordViewMut: set writes into mapped buffer (u32 LE)" {
    const V = WordViewMut(u32, .little);

    var page: [16]u8 = [_]u8{0} ** 16;

    // Map at arbitrary offset (could be unaligned)
    var view = try V.init(page[3..]); // starts at offset 3
    view.set(0xA1B2C3D4);

    // LE bytes at page[3..7]
    try expectBytesEqual(&[_]u8{ 0xD4, 0xC3, 0xB2, 0xA1 }, page[3..7]);
    try std.testing.expectEqual(@as(u32, 0xA1B2C3D4), view.get());
}

test "WordViewConst: reads from mapped buffer (u32 BE)" {
    const Vc = WordViewConst(u32, .big);

    // Put BE bytes at an odd offset
    var page: [16]u8 = [_]u8{0} ** 16;
    page[5] = 0x11;
    page[6] = 0x22;
    page[7] = 0x33;
    page[8] = 0x44;

    const view = try Vc.init(page[5..]);
    try std.testing.expectEqual(@as(u32, 0x11223344), view.get());
}

test "WordView: init errors on too-small slice" {
    const V = WordViewMut(u64, .little);
    var buf: [7]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, V.init(buf[0..]));
}
