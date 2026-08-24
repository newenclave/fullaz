const std = @import("std");
const catalog = @import("fullaz-db").file.catalog_record;
const tagged = @import("fullaz-db").file.tagged_fields;

fn record() catalog.Record {
    return .{
        .component_id = 7,
        .revision = 3,
        .name = "jobs",
        .kind_name = "fullaz.slot-heap.paged",
        .component_format_version = 1,
        .metadata_format_version = 1,
        .page_kind_base = 0x0100,
        .page_kind_count = 3,
        .metadata_root_pid = 42,
        .settings_fingerprint = [_]u8{0x5a} ** 32,
        .dependency_ids = &.{ 2, 5 },
    };
}

test "fullaz-db catalog record: round-trips core and repeated fields" {
    const original = record();
    var bytes = [_]u8{undefined} ** 512;
    var scratch = [_]u8{undefined} ** 512;
    try catalog.format(&bytes, &scratch, original, &.{});

    const encoded_len = try catalog.encodedByteSize(&bytes);
    const decoded = try catalog.read(bytes[0..encoded_len]);
    try std.testing.expectEqual(original.component_id, decoded.component_id);
    try std.testing.expectEqual(original.revision, decoded.revision);
    try std.testing.expectEqualStrings(original.name, decoded.name);
    try std.testing.expectEqualStrings(original.kind_name, decoded.kind_name);
    try std.testing.expectEqual(@as(usize, 2), decoded.dependency_count);
    try std.testing.expectEqual(@as(?u64, 2), try decoded.getDependency(0));
    try std.testing.expectEqual(@as(?u64, 5), try decoded.getDependency(1));
    try std.testing.expectEqual(@as(?u64, null), try decoded.getDependency(2));
}

test "fullaz-db catalog record: preserves unknown fields and rejects malformed core" {
    const original = record();
    var first = [_]u8{undefined} ** 512;
    var first_scratch = [_]u8{undefined} ** 512;
    try catalog.format(&first, &first_scratch, original, &.{});
    const first_len = try catalog.encodedByteSize(&first);

    var previous_payload = [_]u8{undefined} ** 512;
    const first_payload = first[catalog.envelope_byte_size..first_len];
    @memcpy(previous_payload[0..first_payload.len], first_payload);
    var previous = tagged.Writer.init(&previous_payload);
    previous.len = first_payload.len;
    try previous.append(99, 0x8000, "future");

    var second = [_]u8{undefined} ** 512;
    var second_scratch = [_]u8{undefined} ** 512;
    var updated = original;
    updated.revision = 4;
    try catalog.format(&second, &second_scratch, updated, previous.used());
    const second_len = try catalog.encodedByteSize(&second);
    const decoded = try catalog.read(second[0..second_len]);
    try std.testing.expectEqual(@as(u32, 4), decoded.revision);

    var reader = tagged.Reader.init(second[catalog.envelope_byte_size..second_len]);
    var preserved = false;
    while (try reader.next()) |field| {
        if (field.tag == 99) {
            preserved = true;
            try std.testing.expectEqual(@as(u16, 0x8000), field.flags);
            try std.testing.expectEqualStrings("future", field.value);
        }
    }
    try std.testing.expect(preserved);

    var malformed = original;
    malformed.page_kind_base = 0xffff;
    try std.testing.expectError(error.BadCatalogRecord, catalog.format(&second, &second_scratch, malformed, &.{}));
}
