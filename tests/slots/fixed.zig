const std = @import("std");
const Fixed = @import("fullaz").slots.Fixed;
const testing = std.testing;
const printer = @import("test_printer");

const TestSlots = Fixed(u16, u16, .little, false);
const TestSlotsConst = Fixed(u16, u16, .little, true);

const errors = @import("fullaz").core.errors;

test "Slots Fixed: init and format" {
    var buffer = [_]u8{0} ** 128;
    var slot = try TestSlots.init(buffer[0..]);
    try slot.format(16);
    const hdr = slot.header();

    printer.print("Header: one slot: {}, capacity: {}, bitmask words: {}", .{ hdr.one_slot_size.get(), hdr.capacity.get(), hdr.bitmask_words.get() });

    try testing.expectEqual(16, hdr.one_slot_size.get());
    try testing.expect(16 > hdr.capacity.get());
    try testing.expectEqual(1, hdr.bitmask_words.get());
    try testing.expectEqual((try slot.bitset()).bitsCount(), hdr.capacity.get());

    try testing.expectEqual(16, slot.slotSize());
    try testing.expectEqual(hdr.capacity.get(), slot.capacity());
}

test "Slots Fixed: set and get slots" {
    var buffer = [_]u8{0} ** 128;
    var slot = try TestSlots.init(buffer[0..]);
    try slot.format(16);

    const data1 = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const data2 = [_]u8{ 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1 };
    const short_data = [_]u8{ 1, 2, 3 };

    try slot.set(0, data1[0..]);
    try slot.set(1, data2[0..]);
    try slot.set(2, short_data[0..]);

    const got1 = try slot.get(0);
    const got2 = try slot.get(1);
    const got3 = try slot.get(2);

    try testing.expectEqualSlices(u8, data1[0..], got1);
    try testing.expectEqualSlices(u8, data2[0..], got2);
    try testing.expectEqualSlices(u8, short_data[0..], got3[0..3]);
}

test "Slots Fixed: out of bounds" {
    var buffer = [_]u8{0} ** 128;
    var slot = try TestSlots.init(buffer[0..]);
    try slot.format(16);

    const data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };

    try testing.expectError(errors.IndexError.OutOfBounds, slot.set(16, data[0..]));
    try testing.expectError(errors.IndexError.OutOfBounds, slot.get(16));
}

test "Slots Fixed: get free and used" {
    var buffer = [_]u8{0} ** 128;
    var slot = try TestSlots.init(buffer[0..]);
    try slot.format(16);

    const data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };

    try slot.set(6, data[0..]);
    try testing.expectEqual(0, slot.getFirstFree());
    try testing.expectEqual(6, slot.getFirstUsed());
}

test "Slots Fixed: swapUsed swaps complete occupied records" {
    var buffer = [_]u8{0} ** 128;
    var slots = try TestSlots.init(&buffer);
    try slots.format(4);

    try slots.set(0, &.{ 1, 2, 3, 4 });
    try slots.set(1, &.{ 5, 6, 7, 8 });
    const size_before = try slots.size();

    try slots.swapUsed(0, 1);

    try testing.expectEqual(size_before, try slots.size());
    try testing.expectEqualSlices(u8, &.{ 5, 6, 7, 8 }, try slots.get(0));
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, try slots.get(1));
    try testing.expect(try slots.isSet(0));
    try testing.expect(try slots.isSet(1));
}

test "Slots Fixed: swapUsed validates occupied indexes" {
    var buffer = [_]u8{0} ** 128;
    var slots = try TestSlots.init(&buffer);
    try slots.format(4);
    try slots.set(0, &.{ 1, 2, 3, 4 });

    try testing.expectError(error.OutOfBounds, slots.swapUsed(0, 1));
    try testing.expectError(error.OutOfBounds, slots.swapUsed(0, try slots.capacity()));
    try slots.swapUsed(0, 0);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, try slots.get(0));
}

test "Slots Fixed: swapUsed preserves records with big-endian metadata" {
    const BigEndianSlots = Fixed(u16, u16, .big, false);
    var buffer = [_]u8{0} ** 128;
    var slots = try BigEndianSlots.init(&buffer);
    try slots.format(3);
    try slots.set(0, &.{ 0xaa, 0xbb, 0xcc });
    try slots.set(1, &.{ 0x11, 0x22, 0x33 });

    try slots.swapUsed(0, 1);

    try testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33 }, try slots.get(0));
    try testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb, 0xcc }, try slots.get(1));
}

test "Slots Fixed: size does not imply a dense occupied prefix" {
    var buffer = [_]u8{0} ** 128;
    var slots = try TestSlots.init(&buffer);
    try slots.format(4);
    try slots.set(0, &.{ 1, 1, 1, 1 });
    try slots.set(2, &.{ 2, 2, 2, 2 });

    try testing.expectEqual(@as(usize, 2), try slots.size());
    try testing.expectEqual(@as(?usize, 1), try slots.getFirstFree());
    try testing.expect(try slots.isSet(2));
}
