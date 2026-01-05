const std = @import("std");
const PackedInt = @import("packed_int.zig").PackedInt;
const errors = @import("errors.zig");

inline fn ceilWords(value: usize, bits_per_word: usize) usize {
    return (value + bits_per_word - 1) / bits_per_word;
}

inline fn bitmapSizeInBytes(value: usize, bits_per_word: usize, word_bytes: usize) usize {
    if (value == 0) return 0;
    const words = ceilWords(value, bits_per_word);
    return words * word_bytes;
}

pub const CapacityResult = struct {
    bitmap_words: usize,
    objects: usize,
};

pub fn maxObjectsByWords(comptime Word: type, capacity: usize, object_size: usize) CapacityResult {
    if (capacity == 0 or object_size == 0) {
        return .{ .bitmap_words = 0, .objects = 0 };
    }
    const bits_per_word: usize = @bitSizeOf(Word);
    const word_bytes = @sizeOf(Word);

    var low: usize = 0;
    var high: usize = capacity / object_size;
    var best: usize = 0;
    while (low <= high) {
        const mid = low + (high - low) / 2;
        const neededBits = mid;
        const neededBitsetBytes = bitmapSizeInBytes(neededBits, bits_per_word, word_bytes);
        const neededTotalBytes = mid * object_size + neededBitsetBytes;
        if (neededTotalBytes <= capacity) {
            best = mid;
            low = mid + 1;
        } else {
            high = mid - 1;
        }
    }
    const bit_map_words = if (best == 0) 0 else ceilWords(best, bits_per_word);
    return .{ .bitmap_words = bit_map_words, .objects = best };
}

pub fn BitSet(comptime Word: type, comptime Endian: std.builtin.Endian) type {
    const W = PackedInt(Word, Endian);
    const BitsPerWord: usize = @bitSizeOf(Word);
    const ShiftT = std.math.Log2Int(Word);

    comptime {
        switch (@typeInfo(Word)) {
            .int => {},
            else => @compileError("BitSet Word must be integer; got " ++ @typeName(Word)),
        }
    }

    return struct {
        pub const Self = @This();

        words_ro: []const W,
        words_rw: ?[]W,
        max_bits: usize,

        pub fn initConst(bytes: []const u8, maximum: usize) !Self {
            if (bytes.len % @sizeOf(W) != 0) {
                return errors.BufferError.BadLength;
            }
            const words = std.mem.bytesAsSlice(W, bytes);
            const cap_bits = words.len * BitsPerWord;
            return .{
                .words_ro = words,
                .words_rw = null,
                .max_bits = if (maximum < cap_bits) maximum else cap_bits,
            };
        }

        pub fn initMutable(bytes: []u8, maximum: usize) !Self {
            if (bytes.len % @sizeOf(W) != 0) {
                return error.BadLength;
            }
            const words = std.mem.bytesAsSlice(W, bytes);
            const cap_bits = words.len * BitsPerWord;
            return .{
                .words_ro = words,
                .words_rw = words,
                .max_bits = if (maximum < cap_bits) maximum else cap_bits,
            };
        }

        pub fn bitsCount(self: *const Self) usize {
            return self.max_bits;
        }

        pub fn isValid(self: *const Self, pos: usize) bool {
            return pos < self.max_bits;
        }

        pub fn set(self: *Self, bit_pos: usize) !void {
            if (bit_pos >= self.max_bits) {
                return error.IndexOutOfBounds;
            }
            const words = try self.requireWritable();
            const bucket = bit_pos / BitsPerWord;
            const pos = bit_pos % BitsPerWord;
            var v: Word = words.ptr[bucket].get();
            v |= (@as(Word, 1) << @as(ShiftT, @intCast(pos)));
            words.ptr[bucket].set(v);
        }

        pub fn clear(self: *Self, bit_pos: usize) !void {
            if (bit_pos >= self.max_bits) {
                return error.IndexOutOfBounds;
            }
            const words = try self.requireWritable();
            const bucket = bit_pos / BitsPerWord;
            const pos = bit_pos % BitsPerWord;
            var v: Word = words.ptr[bucket].get();
            v &= ~(@as(Word, 1) << @intCast(pos));
            words.ptr[bucket].set(v);
        }

        pub fn reset(self: *Self) !void {
            const words = try self.requireWritable();
            for (words) |*w| {
                w.set(0);
            }
        }

        pub fn isSet(self: *const Self, bit_pos: usize) bool {
            if (bit_pos >= self.max_bits) {
                return false;
            }
            const bucket = bit_pos / BitsPerWord;
            const pos = bit_pos % BitsPerWord;
            const v: Word = self.words_ro.ptr[bucket].get();
            return (v & (@as(Word, 1) << @as(ShiftT, @intCast(pos)))) != 0;
        }

        pub fn findZeroBit(self: *const Self) ?usize {
            const full: Word = std.math.maxInt(Word);
            const n_words = self.words_ro.len;

            var b: usize = 0;
            while (b < n_words) : (b += 1) {
                const v: Word = self.words_ro.ptr[b].get();
                if (v == full) {
                    continue;
                }

                const inv: Word = ~v;
                const first_zero: usize = if (inv != 0) @intCast(@ctz(inv)) else scanFirstZero(v);

                const bit_pos = b * BitsPerWord + first_zero;
                if (bit_pos < self.max_bits) {
                    return bit_pos;
                }
            }
            return null;
        }

        pub fn findSetBit(self: *const Self) ?usize {
            const n_words = self.words_ro.len;

            var b: usize = 0;
            while (b < n_words) : (b += 1) {
                const v: Word = self.words_ro.ptr[b].get();
                if (v == 0) {
                    continue;
                }

                const first_set: usize = @intCast(@ctz(v));
                const bit_pos = b * BitsPerWord + first_set;
                if (bit_pos < self.max_bits) return bit_pos;
            }
            return null;
        }

        pub fn popcount(self: *const Self) usize {
            var total: usize = 0;
            for (self.words_ro) |*w| {
                const v: Word = w.get();
                total += @intCast(@popCount(v));
            }
            return total;
        }

        // --- helpers ---
        fn requireWritable(self: *Self) ![]W {
            if (self.words_rw) |w| {
                return w;
            }
            return error.ReadOnly;
        }

        inline fn scanFirstZero(v: Word) usize {
            var i: usize = 0;
            while (i < BitsPerWord) : (i += 1) {
                if ((v & (@as(Word, 1) << @intCast(i))) == 0) {
                    return i;
                }
            }
            return BitsPerWord;
        }
    };
}
