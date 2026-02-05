const BitSet = @import("fullaz").core.bitset.BitSet;
const std = @import("std");
const expect = std.testing.expect;

test "create bitset" {
    var buffer: [8]u8 = undefined;
    var bs = try BitSet(u32, .little).initMutable(buffer[0..], 64);
    try bs.reset();

    try expect(bs.bitsCount() == 64);

    try bs.set(2);
    try bs.set(4);
    try bs.set(6);

    try expect(bs.findZeroBit() == 0);
    try expect(bs.isSet(2));

    try bs.clear(2);
    try expect(!bs.isSet(2));
    try expect(!bs.isSet(3));
    try expect(bs.isSet(4));
    try expect(!bs.isSet(5));
    try expect(bs.isSet(6));
    try expect(bs.popcount() == 2);
}

test "bitset: boundaries, idempotence, reset" {
    var buffer: [8]u8 = undefined;
    var bs = try BitSet(u32, .little).initMutable(buffer[0..], 64);
    try bs.reset();

    try expect(bs.bitsCount() == 64);
    try expect(bs.popcount() == 0);

    // set(0) and set(63)
    try bs.set(0);
    try bs.set(63);
    try expect(bs.isSet(0));
    try expect(bs.isSet(63));
    try expect(bs.popcount() == 2);

    try bs.set(0);
    try bs.set(63);
    try expect(bs.popcount() == 2);

    try bs.clear(0);
    try bs.clear(63);
    try expect(!bs.isSet(0));
    try expect(!bs.isSet(63));
    try expect(bs.popcount() == 0);

    // Repeated clear should not change popcount
    try bs.clear(0);
    try bs.clear(63);
    try expect(bs.popcount() == 0);

    // reset should clear everything again (idempotence)
    try bs.set(1);
    try bs.set(2);
    try expect(bs.popcount() == 2);
    try bs.reset();
    try expect(bs.popcount() == 0);
    for (0..bs.bitsCount()) |i| {
        try expect(!bs.isSet(i));
    }
}

test "bitset: set even bits, then odd bits" {
    var buffer: [8]u8 = undefined;
    var bs = try BitSet(u32, .little).initMutable(buffer[0..], 64);
    try bs.reset();

    // Set all even bits: expect 32
    for (0..64) |i| {
        if ((i & 1) == 0) try bs.set(i);
    }
    try expect(bs.popcount() == 32);

    // Check selectively
    try expect(bs.isSet(0));
    try expect(!bs.isSet(1));
    try expect(bs.isSet(62));
    try expect(!bs.isSet(63));

    // Now set all odd bits: expect 64
    for (0..64) |i| {
        if ((i & 1) == 1) try bs.set(i);
    }
    try expect(bs.popcount() == 64);

    // Clear all even bits: expect 32 (only odd remain)
    for (0..64) |i| {
        if ((i & 1) == 0) try bs.clear(i);
    }
    try expect(bs.popcount() == 32);
    try expect(!bs.isSet(0));
    try expect(bs.isSet(1));
    try expect(!bs.isSet(62));
    try expect(bs.isSet(63));
}

test "bitset: fill contiguous blocks, verify edges and popcount" {
    var buffer: [8]u8 = undefined;
    var bs = try BitSet(u32, .little).initMutable(buffer[0..], 64);
    try bs.reset();

    for (8..16) |i| try bs.set(i);
    try expect(bs.popcount() == 8);
    try expect(!bs.isSet(7));
    try expect(bs.isSet(8));
    try expect(bs.isSet(15));
    try expect(!bs.isSet(16));

    for (32..48) |i| try bs.set(i);
    try expect(bs.popcount() == 8 + 16);

    for (10..14) |i| try bs.clear(i);
    try expect(bs.isSet(8));
    try expect(bs.isSet(9));
    try expect(!bs.isSet(10));
    try expect(!bs.isSet(11));
    try expect(!bs.isSet(12));
    try expect(!bs.isSet(13));
    try expect(bs.isSet(14));
    try expect(bs.isSet(15));

    const expected = (8 - 4) + 16;
    try expect(bs.popcount() == expected);
}

test "bitset: findZeroBit after progressive filling and after creating a hole" {
    var buffer: [8]u8 = undefined;
    var bs = try BitSet(u32, .little).initMutable(buffer[0..], 64);
    try bs.reset();

    // 0 is the first zero bit
    try expect(bs.findZeroBit() == 0);

    for (0..10) |i| try bs.set(i);
    try expect(bs.findZeroBit() == 10);

    try bs.clear(3);
    try expect(bs.findZeroBit() == 3);

    try bs.set(3);
    try expect(bs.findZeroBit() == 10);
    for (10..63) |i| try bs.set(i);
    try expect(bs.findZeroBit() == 63);

    try bs.clear(20);
    try expect(bs.findZeroBit() == 20);
}

test "bitset: pseudo-random toggles with popcount tracking" {
    var buffer: [8]u8 = undefined;
    var bs = try BitSet(u32, .little).initMutable(buffer[0..], 64);
    try bs.reset();

    var shadow: [64]bool = .{false} ** 64;
    var ones: usize = 0;

    // Deterministic LCG: simple index generator [0..63]
    var seed: u64 = 0x1234_5678_9ABC_DEF0;
    inline for (0..512) |_| { // 512 operations
        seed = seed *% 6364136223846793005 +% 1;
        const idx: usize = @as(usize, @intCast(seed >> 58)); // 6 bits — 0..63

        if ((seed & 1) == 0) {
            // set
            if (!shadow[idx]) {
                shadow[idx] = true;
                ones += 1;
            }
            try bs.set(idx);
        } else {
            // clear
            if (shadow[idx]) {
                shadow[idx] = false;
                ones -= 1;
            }
            try bs.clear(idx);
        }
    }

    try expect(bs.popcount() == ones);
    for (0..64) |i| {
        try expect(bs.isSet(i) == shadow[i]);
    }
}

test "bitset: logical equivalence little vs big endian (basic)" {
    var buf_le: [8]u8 = undefined;
    var buf_be: [8]u8 = undefined;

    var bs_le = try BitSet(u32, .little).initMutable(buf_le[0..], 64);
    var bs_be = try BitSet(u32, .big).initMutable(buf_be[0..], 64);

    try bs_le.reset();
    try bs_be.reset();

    const indices = [_]usize{ 0, 1, 2, 3, 4, 5, 8, 15, 16, 31, 32, 47, 48, 63 };
    for (indices) |i| {
        try bs_le.set(i);
        try bs_be.set(i);
    }
    try expect(bs_le.popcount() == bs_be.popcount());

    for (indices) |i| {
        try expect(bs_le.isSet(i));
        try expect(bs_be.isSet(i));
    }

    // Now clear some bits and check again
    const to_clear = [_]usize{ 1, 5, 15, 31, 47, 63 };
    for (to_clear) |i| {
        try bs_le.clear(i);
        try bs_be.clear(i);
    }
    try expect(bs_le.popcount() == bs_be.popcount());

    for (0..64) |i| {
        try expect(bs_le.isSet(i) == bs_be.isSet(i));
    }
}

test "bitset: invariants after mixed operations and reset" {
    var buffer: [8]u8 = undefined;
    var bs = try BitSet(u32, .little).initMutable(buffer[0..], 64);
    try bs.reset();

    try bs.set(10);
    try bs.set(11);
    try bs.clear(10);
    try bs.set(12);
    try bs.set(63);
    try bs.clear(63);
    try bs.set(0);
    try bs.set(63);

    try expect(bs.isSet(0));
    try expect(bs.isSet(11));
    try expect(bs.isSet(12));
    try expect(bs.isSet(63));
    try expect(!bs.isSet(10));
    try expect(bs.popcount() == 4);

    try bs.reset();
    try expect(bs.popcount() == 0);
    for (0..64) |i| {
        try expect(!bs.isSet(i));
    }
}

const maxObjectsByWords = @import("fullaz").core.bitset.maxObjectsByWords;

const expectEqual = std.testing.expectEqual;

inline fn bitsPerWord(comptime Word: type) usize {
    return @bitSizeOf(Word);
}

inline fn ceilWords(x: usize, comptime Word: type) usize {
    const bpw = bitsPerWord(Word);
    return if (x == 0) 0 else (x + bpw - 1) / bpw;
}

test "max_objects_by_words: zero capacity" {
    const r32 = maxObjectsByWords(u32, 0, 16);
    try expectEqual(@as(usize, 0), r32.bitmap_words);
    try expectEqual(@as(usize, 0), r32.objects);

    const r64 = maxObjectsByWords(u64, 0, 16);
    try expectEqual(@as(usize, 0), r64.bitmap_words);
    try expectEqual(@as(usize, 0), r64.objects);
}

test "max_objects_by_words: zero object_size" {
    const r32 = maxObjectsByWords(u32, 1024, 0);
    try expectEqual(@as(usize, 0), r32.bitmap_words);
    try expectEqual(@as(usize, 0), r32.objects);

    const r64 = maxObjectsByWords(u64, 1024, 0);
    try expectEqual(@as(usize, 0), r64.bitmap_words);
    try expectEqual(@as(usize, 0), r64.objects);
}

test "max_objects_by_words: exact fit, u32" {
    const capacity = 128;
    const object_size = 16;

    const r = maxObjectsByWords(u32, capacity, object_size);
    const best = r.objects;
    const words = r.bitmap_words;

    const word_bytes = @sizeOf(u32); // 4 байта
    const bitmap_bytes = ceilWords(best, u32) * word_bytes;

    try expect((best * object_size + bitmap_bytes) <= capacity);

    const bitmap_bytes_plus = ceilWords(best + 1, u32) * word_bytes;
    try expect(!((best + 1) * object_size + bitmap_bytes_plus <= capacity));

    try expectEqual(ceilWords(best, u32), words);
}

test "max_objects_by_words: exact fit, u64" {
    const capacity = 128;
    const object_size = 16;

    const r = maxObjectsByWords(u64, capacity, object_size);
    const best = r.objects;
    const words = r.bitmap_words;

    //const bpw = bits_per_word(u64); // 64 bits
    const word_bytes = @sizeOf(u64); // 8 байт
    const bitmap_bytes = ceilWords(best, u64) * word_bytes;

    try expect((best * object_size + bitmap_bytes) <= capacity);

    const bitmap_bytes_plus = ceilWords(best + 1, u64) * word_bytes;
    try expect(!((best + 1) * object_size + bitmap_bytes_plus <= capacity));

    try expectEqual(ceilWords(best, u64), words);
}

test "max_objects_by_words: one byte short prevents extra object (u32)" {
    const object_size = 24;
    const target_objects = 5;

    const word_bytes = @sizeOf(u32); // 4
    const bitmap_words = ceilWords(target_objects, u32);
    const bitmap_bytes = bitmap_words * word_bytes;
    const capacity_exact = target_objects * object_size + bitmap_bytes;

    const r_exact = maxObjectsByWords(u32, capacity_exact, object_size);
    try expectEqual(bitmap_words, r_exact.bitmap_words);
    try expectEqual(target_objects, r_exact.objects);

    const r_short = maxObjectsByWords(u32, capacity_exact - 1, object_size);
    try expect(r_short.objects < target_objects);
}

test "max_objects_by_words: stress different capacities (u64)" {
    const object_size = 10;
    inline for (.{ 1, 2, 3, 7, 8, 9, 15, 16, 31, 32, 63, 64, 127, 128, 1024 }) |cap| {
        const r = maxObjectsByWords(u64, cap, object_size);
        const best = r.objects;

        const word_bytes = @sizeOf(u64); // 8
        const bitmap_bytes_best = ceilWords(best, u64) * word_bytes;
        const bitmap_bytes_next = ceilWords(best + 1, u64) * word_bytes;

        try expect(best * object_size + bitmap_bytes_best <= cap);
        try expect(!((best + 1) * object_size + bitmap_bytes_next <= cap));
    }
}

test "max_objects_by_words: large capacity scaling (u32)" {
    const object_size = 1; // small objects
    const cap = 10_000;

    const r = maxObjectsByWords(u32, cap, object_size);
    const best = r.objects;
    const words = r.bitmap_words;

    const word_bytes = @sizeOf(u32); // 4
    const bitmap_bytes = ceilWords(best, u32) * word_bytes;

    try expect(best + bitmap_bytes <= cap);

    const bitmap_bytes_plus = ceilWords(best + 1, u32) * word_bytes;
    try expect(!((best + 1) + bitmap_bytes_plus <= cap));

    try expectEqual(ceilWords(best, u32), words);
}
