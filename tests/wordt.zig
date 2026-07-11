const std = @import("std");

const errors = @import("fullaz").errors;

const fullaz = @import("fullaz");
const PackedInt = fullaz.core.packed_int.PackedInt;
const PackedIntLe = fullaz.core.packed_int.PackedIntLe;
const PackedIntBe = fullaz.core.packed_int.PackedIntBe;
const PackedFloat = fullaz.core.packed_int.PackedFloat;
const PackedNumber = fullaz.core.packed_int.PackedNumber;

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
// Tests: PackedFloat + PackedNumber selector
// ---------------------------------------------
test "PackedFloat: init/get/set roundtrip (f64)" {
    var w = PackedFloat(f64, .little).init(3.5);
    try std.testing.expectEqual(@as(f64, 3.5), w.get());
    w.set(-2.25);
    try std.testing.expectEqual(@as(f64, -2.25), w.get());
}

test "PackedFloat: byte order matches the IEEE-754 bits (f32)" {
    // 1.0f == 0x3F800000
    const le = PackedFloat(f32, .little).init(1.0);
    try expectBytesEqual(&[_]u8{ 0x00, 0x00, 0x80, 0x3F }, le.bytes[0..]);

    const be = PackedFloat(f32, .big).init(1.0);
    try expectBytesEqual(&[_]u8{ 0x3F, 0x80, 0x00, 0x00 }, be.bytes[0..]);
}

test "PackedFloat: fromSlice/writeTo roundtrip and short-buffer error" {
    const W = PackedFloat(f64, .big);
    const w = W.init(12345.678);

    var buf: [8]u8 = undefined;
    try w.writeTo(buf[0..]);
    const w2 = try W.fromSlice(buf[0..]);
    try std.testing.expectEqual(@as(f64, 12345.678), w2.get());

    var too_small: [3]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, w.writeTo(too_small[0..]));
}

test "PackedFloat: bit-exact roundtrip incl. inf/nan/negzero" {
    inline for (.{ f16, f32, f64, f128 }) |T| {
        inline for (.{ std.builtin.Endian.little, std.builtin.Endian.big }) |E| {
            const W = PackedFloat(T, E);
            const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));

            var prng = std.Random.DefaultPrng.init(0xF10A7);
            const rnd = prng.random();

            const specials = [_]T{ 0.0, -0.0, std.math.inf(T), -std.math.inf(T), std.math.nan(T) };
            for (specials) |val| {
                const w = W.init(val);
                // Compare bit patterns so NaN and -0.0 verify exactly.
                try std.testing.expectEqual(@as(Bits, @bitCast(val)), @as(Bits, @bitCast(w.get())));
            }

            var i: usize = 0;
            while (i < 200) : (i += 1) {
                const bits: Bits = rnd.int(Bits);
                const val: T = @bitCast(bits);
                const w = W.init(val);
                try std.testing.expectEqual(bits, @as(Bits, @bitCast(w.get())));
            }
        }
    }
}

test "PackedNumber: selects PackedInt for ints and PackedFloat for floats" {
    try std.testing.expect(PackedNumber(u32, .little) == PackedInt(u32, .little));
    try std.testing.expect(PackedNumber(i64, .big) == PackedInt(i64, .big));
    try std.testing.expect(PackedNumber(f32, .little) == PackedFloat(f32, .little));
    try std.testing.expect(PackedNumber(f64, .big) == PackedFloat(f64, .big));

    // Both branches are usable through the same surface.
    var wi = PackedNumber(i32, .little).init(-7);
    try std.testing.expectEqual(@as(i32, -7), wi.get());
    var wf = PackedNumber(f32, .little).init(1.5);
    try std.testing.expectEqual(@as(f32, 1.5), wf.get());
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
