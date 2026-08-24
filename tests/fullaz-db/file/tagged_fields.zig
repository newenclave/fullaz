const std = @import("std");
const tagged = @import("fullaz-db").file.tagged_fields;

test "fullaz-db tagged fields: round-trip uses fixed little-endian headers" {
    var bytes: [32]u8 = undefined;
    var writer = tagged.Writer.init(&bytes);
    try writer.append(7, 0x1234, "value");

    try std.testing.expectEqualSlices(
        u8,
        &.{ 7, 0, 0x34, 0x12, 5, 0, 0, 0, 'v', 'a', 'l', 'u', 'e' },
        writer.used(),
    );

    var reader = tagged.Reader.init(writer.used());
    const field = (try reader.next()).?;
    try std.testing.expectEqual(@as(u16, 7), field.tag);
    try std.testing.expectEqual(@as(u16, 0x1234), field.flags);
    try std.testing.expectEqualStrings("value", field.value);
    try std.testing.expect((try reader.next()) == null);
}

test "fullaz-db tagged fields: unknown fields retain exact encoded bytes" {
    var previous_bytes: [64]u8 = undefined;
    var previous = tagged.Writer.init(&previous_bytes);
    try previous.append(1, 0, "old");
    try previous.append(99, 0x8000, "unknown");

    var next_bytes: [64]u8 = undefined;
    var next = tagged.Writer.init(&next_bytes);
    try tagged.copyUnknownFields(&next, previous.used(), &.{1});
    try next.append(1, 0, "new");

    var reader = tagged.Reader.init(next.used());
    const unknown = (try reader.next()).?;
    try std.testing.expectEqual(@as(u16, 99), unknown.tag);
    try std.testing.expectEqual(@as(u16, 0x8000), unknown.flags);
    try std.testing.expectEqualStrings("unknown", unknown.value);
    const known = (try reader.next()).?;
    try std.testing.expectEqual(@as(u16, 1), known.tag);
    try std.testing.expectEqualStrings("new", known.value);
}

test "fullaz-db tagged fields: rejects malformed and duplicate known fields" {
    var bytes: [32]u8 = undefined;
    var writer = tagged.Writer.init(&bytes);
    try writer.append(1, 0, "first");
    try writer.append(1, 0, "second");
    try std.testing.expectError(
        error.DuplicateKnownField,
        tagged.validateKnownFields(writer.used(), &.{1}),
    );

    var truncated_header = [_]u8{ 1, 0, 0, 0 };
    var zero_tag = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    var truncated_value = [_]u8{ 1, 0, 0, 0, 1, 0, 0, 0 };
    var truncated_header_reader = tagged.Reader.init(&truncated_header);
    var zero_tag_reader = tagged.Reader.init(&zero_tag);
    var truncated_value_reader = tagged.Reader.init(&truncated_value);
    try std.testing.expectError(error.BadTaggedFields, truncated_header_reader.next());
    try std.testing.expectError(error.BadTaggedFields, zero_tag_reader.next());
    try std.testing.expectError(error.BadTaggedFields, truncated_value_reader.next());
}

test "fullaz-db tagged fields: writer rejects a short destination" {
    var bytes: [8]u8 = undefined;
    var writer = tagged.Writer.init(&bytes);
    try std.testing.expectError(error.BufferTooSmall, writer.append(1, 0, "x"));
}
