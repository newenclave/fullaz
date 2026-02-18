const std = @import("std");
const core = @import("../core/core.zig");
const errors = core.errors;
const bit_set = @import("../core/bitset.zig");

const PackedInt = core.packed_int.PackedInt;

pub fn Fixed(comptime BitSetDataType: type, comptime SizeT: type, comptime Endian: std.builtin.Endian, comptime read_only: bool) type {
    const BufferType = if (read_only) []const u8 else []u8;

    const BitSet = bit_set.BitSet(BitSetDataType, Endian);
    const SizeType = PackedInt(SizeT, Endian);

    const Header = extern struct {
        one_slot_size: SizeType, // one slot size in bytes
        capacity: SizeType, // bits used
        bitmask_words: SizeType, // number of words used for bitmask
    };

    return struct {
        const Self = @This();

        hdr_buf: BufferType,
        body: BufferType,
        const Error = errors.SpaceError ||
            errors.IndexError ||
            BitSet.Error;

        pub fn init(body: BufferType) Error!Self {
            if (body.len < @sizeOf(Header)) {
                return Error.BufferTooSmall;
            }
            return Self{
                .hdr_buf = body[0..@sizeOf(Header)],
                .body = body[@sizeOf(Header)..],
            };
        }

        pub fn format(self: *Self, slot_size: usize) Error!void {
            if (read_only) {
                @compileError("Unable format readonly data");
            }
            const maximum_objects = bit_set.maxObjectsByWords(BitSetDataType, self.body.len, slot_size);
            var hdr = self.headerMut();
            hdr.one_slot_size.set(@as(SizeT, @intCast(slot_size)));
            hdr.capacity.set(@as(SizeT, @intCast(maximum_objects.objects)));
            hdr.bitmask_words.set(@as(SizeT, @intCast(maximum_objects.bitmap_words)));
            var bm = try self.bitsetMut();
            try bm.reset();
        }

        pub fn size(self: *const Self) Error!usize {
            const bs = try self.bitset();
            return bs.popcount();
        }

        pub fn capacity(self: *const Self) Error!usize {
            const bs = try self.bitset();
            return bs.bitsCount();
        }

        pub fn isSet(self: *const Self, pos: usize) Error!bool {
            const bs = try self.bitset();
            return bs.isSet(pos);
        }

        pub fn set(self: *Self, pos: usize, value: []const u8) Error!void {
            if (read_only) {
                @compileError("Unable set slot on readonly data");
            }

            var slot = try self.getSlotMut(pos);
            if (slot.len < value.len) {
                return Error.BadLength;
            }
            slot = slot[0..value.len];

            @memcpy(slot, value);
            var bm = try self.bitsetMut();
            try bm.set(pos);
        }

        pub fn get(self: *const Self, pos: usize) Error![]const u8 {
            const is_set = try self.isSet(pos);
            if (!is_set) {
                return Error.OutOfBounds;
            }
            return try self.getSlot(pos);
        }

        pub fn free(self: *Self, pos: usize) Error!void {
            if (read_only) {
                @compileError("Unable free slot on readonly data");
            }
            var bs = try self.bitsetMut();
            try bs.clear(pos);
        }

        pub fn getFirstFree(self: *const Self) Error!?usize {
            const bs = try self.bitset();
            return bs.findZeroBit();
        }

        pub fn getFirstUsed(self: *const Self) Error!?usize {
            const bs = try self.bitset();
            return bs.findSetBit();
        }

        pub fn slotSize(self: *const Self) Error!usize {
            const hdr = self.header();
            return @as(usize, @intCast(hdr.one_slot_size.get()));
        }

        pub fn header(self: *const Self) *const Header {
            return @ptrCast(&self.hdr_buf[0]);
        }

        fn headerMut(self: *Self) *Header {
            return @ptrCast(&self.hdr_buf[0]);
        }

        fn getSlotsBody(self: *const Self) []const u8 {
            const hdr = self.header();
            const bitmask_words: usize = @as(usize, @intCast(hdr.bitmask_words.get()));
            const vs_body_len = bitmask_words * @sizeOf(BitSetDataType);
            return self.body[vs_body_len..];
        }

        fn getSlot(self: *const Self, pos: usize) Error![]const u8 {
            const slots = self.getSlotsBody();
            const hdr = self.header();
            const slot_size: usize = @as(usize, @intCast(hdr.one_slot_size.get()));
            const cap: usize = @as(usize, @intCast(hdr.capacity.get()));
            if (pos >= cap) {
                return Error.OutOfBounds;
            }
            const slot_begin = pos * slot_size;
            const slot_end = slot_begin + slot_size;
            if (slot_end > slots.len) {
                return Error.OutOfBounds;
            }
            return slots[slot_begin..slot_end];
        }

        fn getSlotMut(self: *Self, pos: usize) Error![]u8 {
            const slots = self.getSlotsBodyMut();
            const hdr = self.headerMut();
            const slot_size: usize = @as(usize, @intCast(hdr.one_slot_size.get()));
            const cap: usize = @as(usize, @intCast(hdr.capacity.get()));
            if (pos >= cap) {
                return Error.OutOfBounds;
            }
            const slot_begin = pos * slot_size;
            const slot_end = slot_begin + slot_size;
            if (slot_end > slots.len) {
                return Error.OutOfBounds;
            }
            return slots[slot_begin..slot_end];
        }

        fn getSlotsBodyMut(self: *Self) []u8 {
            const hdr = self.header();
            const bitmask_words: usize = @intCast(hdr.bitmask_words.get());
            const vs_body_len = bitmask_words * @sizeOf(BitSetDataType);
            return self.body[vs_body_len..];
        }

        pub fn bitset(self: *const Self) Error!BitSet {
            const hdr = self.header();
            const bitmask_words: usize = @intCast(hdr.bitmask_words.get());
            const bitmask_size: usize = @intCast(hdr.capacity.get());
            const bs_body = self.body[0..(bitmask_words * @sizeOf(BitSetDataType))];
            return try BitSet.initConst(bs_body, bitmask_size);
        }

        fn bitsetMut(self: *Self) Error!BitSet {
            const hdr = self.headerMut();
            const bitmask_words: usize = @intCast(hdr.bitmask_words.get());
            const bitmask_size: usize = @intCast(hdr.capacity.get());
            const bs_body = self.body[0..(bitmask_words * @sizeOf(BitSetDataType))];
            return try BitSet.initMutable(bs_body, bitmask_size);
        }
    };
}
