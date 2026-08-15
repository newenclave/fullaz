const std = @import("std");
const Trailing = @import("fullaz").slots.Trailing;

const Mutable = Trailing(u16, .little, false);
const ReadOnly = Trailing(u16, .little, true);
const BigEndian = Trailing(u16, .big, false);

test "Trailing reserves records in logical slot order" {
    var buffer: [128]u8 = undefined;
    var slots = try Mutable.init(&buffer);
    slots.format();

    const first = try slots.reserve(3);
    @memcpy(first.bytes, "one");
    const second = try slots.reserve(3);
    @memcpy(second.bytes, "two");
    const inserted = try slots.reserveAt(1, 6);
    @memcpy(inserted.bytes, "middle");

    try std.testing.expectEqual(@as(usize, 0), first.slot_id);
    try std.testing.expectEqual(@as(usize, 1), second.slot_id);
    try std.testing.expectEqual(@as(usize, 1), inserted.slot_id);
    try std.testing.expectEqual(@as(usize, 3), slots.entryCount());
    try std.testing.expectEqualSlices(u8, "one", try slots.get(0));
    try std.testing.expectEqualSlices(u8, "middle", try slots.get(1));
    try std.testing.expectEqualSlices(u8, "two", try slots.get(2));

    const first_entry = try slots.entry(0);
    const last_entry = try slots.entry(2);
    try std.testing.expect(first_entry.offset.get() < last_entry.offset.get());
}

test "Trailing compacts and reopens with more capacity" {
    var build_buffer: [128]u8 = undefined;
    var builder = try Mutable.init(&build_buffer);
    builder.format();
    const first = try builder.reserve(5);
    @memcpy(first.bytes, "alpha");
    const second = try builder.reserve(4);
    @memcpy(second.bytes, "beta");
    const compact_bytes = try builder.compact();

    try std.testing.expect(compact_bytes < build_buffer.len);
    var read_only = try ReadOnly.open(build_buffer[0..compact_bytes]);
    try std.testing.expectEqualSlices(u8, "alpha", try read_only.get(0));
    try std.testing.expectEqualSlices(u8, "beta", try read_only.get(1));

    var expanded_buffer: [256]u8 = undefined;
    @memcpy(expanded_buffer[0..compact_bytes], build_buffer[0..compact_bytes]);
    var reopened = try Mutable.open(&expanded_buffer);
    const third = try reopened.reserve(5);
    @memcpy(third.bytes, "gamma");
    const expanded_compact_bytes = try reopened.compact();

    read_only = try ReadOnly.open(expanded_buffer[0..expanded_compact_bytes]);
    try std.testing.expectEqualSlices(u8, "alpha", try read_only.get(0));
    try std.testing.expectEqualSlices(u8, "beta", try read_only.get(1));
    try std.testing.expectEqualSlices(u8, "gamma", try read_only.get(2));
}

test "Trailing validates compact layout and capacity" {
    var buffer: [16]u8 = undefined;
    var slots = try Mutable.init(&buffer);
    slots.format();
    try std.testing.expect(slots.canReserve(6));
    const record = try slots.reserve(6);
    @memcpy(record.bytes, "record");
    try std.testing.expect(!slots.canReserve(1));
    try std.testing.expectError(error.NotEnoughSpace, slots.reserve(1));

    const compact_bytes = try slots.compact();
    var corrupt = buffer;
    var corrupt_slots = try Mutable.open(&corrupt);
    corrupt_slots.headerMut().directory_offset.set(0);
    try std.testing.expectError(
        error.InconsistentLayout,
        ReadOnly.open(corrupt[0..compact_bytes]),
    );
}

test "Trailing packs big-endian entries" {
    var buffer: [64]u8 = undefined;
    var slots = try BigEndian.init(&buffer);
    slots.format();
    const record = try slots.reserve(3);
    @memcpy(record.bytes, "big");
    const compact_bytes = try slots.compact();

    const ReadOnlyBigEndian = Trailing(u16, .big, true);
    var read_only = try ReadOnlyBigEndian.open(buffer[0..compact_bytes]);
    try std.testing.expectEqualSlices(u8, "big", try read_only.get(0));
}
