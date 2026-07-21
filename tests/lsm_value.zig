const std = @import("std");
const fullaz = @import("fullaz");
const value = fullaz.lsm.value;

test "LSM value: module-level tagOf/isTombstone read the tag byte regardless of LsnT" {
    var buf: [64]u8 = undefined;

    const Value16 = value.Value(u16, .native);
    const put_enc = Value16.encodePut(&buf, "hello", 1);
    try std.testing.expectEqual(value.Tag.put, value.tagOf(put_enc));
    try std.testing.expect(!value.isTombstone(put_enc));

    const Value64 = value.Value(u64, .big);
    const tomb_enc = Value64.encodeTombstone(&buf, 1);
    try std.testing.expectEqual(value.Tag.tombstone, value.tagOf(tomb_enc));
    try std.testing.expect(value.isTombstone(tomb_enc));
}

test "LSM value: generic Value put round-trips tag, lsn and payload" {
    var buf: [64]u8 = undefined;
    const Value = value.Value(u16, .native);
    const enc = Value.encodePut(&buf, "hello", 123);
    try std.testing.expectEqual(value.Tag.put, Value.tagOf(enc));
    try std.testing.expect(!Value.isTombstone(enc));
    try std.testing.expectEqualSlices(u8, "hello", Value.payloadOf(enc));
    try std.testing.expectEqual(@as(u16, 123), Value.lsnOf(enc));
    try std.testing.expectEqual(Value.encodedLen(5), enc.len);
}

test "LSM value: generic Value tombstone carries its lsn" {
    var buf: [64]u8 = undefined;
    const Value = value.Value(u16, .native);
    const enc = Value.encodeTombstone(&buf, 7);
    try std.testing.expectEqual(value.Tag.tombstone, Value.tagOf(enc));
    try std.testing.expect(Value.isTombstone(enc));
    try std.testing.expectEqual(@as(usize, 0), Value.payloadOf(enc).len);
    try std.testing.expectEqual(@as(u16, 7), Value.lsnOf(enc));
    try std.testing.expectEqual(Value.encodedLen(0), enc.len);
}
