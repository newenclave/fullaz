const std = @import("std");
const fullaz = @import("fullaz");
const value = fullaz.lsm.value;

test "LSM value: put round-trips tag and payload" {
    var buf: [64]u8 = undefined;
    const enc = value.encodePut(&buf, "hello");
    try std.testing.expectEqual(value.Tag.put, value.tagOf(enc));
    try std.testing.expect(!value.isTombstone(enc));
    try std.testing.expectEqualSlices(u8, "hello", value.payloadOf(enc));
    try std.testing.expectEqual(@as(usize, 6), enc.len);
}

test "LSM value: tombstone tag is set with empty payload" {
    var buf: [64]u8 = undefined;
    const enc = value.encodeTombstone(&buf);
    try std.testing.expectEqual(value.Tag.tombstone, value.tagOf(enc));
    try std.testing.expect(value.isTombstone(enc));
    try std.testing.expectEqual(@as(usize, 0), value.payloadOf(enc).len);
    try std.testing.expectEqual(@as(usize, 1), enc.len);
}

test "LSM value: encodedLen is payload plus tag byte" {
    try std.testing.expectEqual(@as(usize, 1), value.encodedLen(0));
    try std.testing.expectEqual(@as(usize, 11), value.encodedLen(10));
}
