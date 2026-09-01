const std = @import("std");
const envelope = @import("fullaz-db").value_envelope;

const metadata = envelope.Metadata{
    .registry_id = 0x0102_0304_0506_0708,
    .type_id = 0x1112_1314_1516_1718,
    .type_version = 7,
    .metadata_format_version = 3,
    .instance_id = 42,
    .revision = 9,
};

const type_identity = envelope.TypeIdentity{
    .registry_id = metadata.registry_id,
    .type_id = metadata.type_id,
    .type_version = metadata.type_version,
    .metadata_format_version = metadata.metadata_format_version,
};

test "fullaz-db value envelope: raw and embedded values round-trip" {
    var raw_bytes: [80]u8 = undefined;
    try envelope.formatRaw(&raw_bytes, metadata, "raw");
    const raw = try envelope.readRaw(&raw_bytes, type_identity);
    try std.testing.expectEqual(envelope.Kind.raw, raw.kind);
    try std.testing.expectEqual(metadata, raw.metadata);
    try std.testing.expectEqualSlices(u8, "raw", raw.payload);

    var embedded_bytes: [80]u8 = undefined;
    try envelope.formatEmbedded(&embedded_bytes, metadata, "embedded");
    const embedded = try envelope.readEmbedded(&embedded_bytes, type_identity);
    try std.testing.expectEqual(envelope.Kind.embedded, embedded.kind);
    try std.testing.expectEqual(metadata, embedded.metadata);
    try std.testing.expectEqualSlices(u8, "embedded", embedded.payload);
}

test "fullaz-db value envelope: rejects corruption, incorrect kind, type, and version" {
    var bytes: [80]u8 = undefined;
    try envelope.formatRaw(&bytes, metadata, "value");
    bytes[envelope.envelope_byte_size] ^= 1;
    try std.testing.expectError(error.BadCrc, envelope.readRaw(&bytes, type_identity));

    try envelope.formatRaw(&bytes, metadata, "value");
    try std.testing.expectError(error.IncorrectKind, envelope.readEmbedded(&bytes, type_identity));

    const wrong_type = envelope.TypeIdentity{
        .registry_id = metadata.registry_id,
        .type_id = metadata.type_id + 1,
        .type_version = metadata.type_version,
        .metadata_format_version = metadata.metadata_format_version,
    };
    try std.testing.expectError(error.IncorrectType, envelope.readRaw(&bytes, wrong_type));

    bytes[4] = 2;
    bytes[5] = 0;
    try std.testing.expectError(error.UnsupportedFormatVersion, envelope.readRaw(&bytes, type_identity));
}

test "fullaz-db value envelope: fixes capacity and requires zero padding" {
    var bytes: [96]u8 = undefined;
    try envelope.formatEmbedded(&bytes, metadata, "data");
    const value = try envelope.readEmbedded(&bytes, type_identity);
    try std.testing.expectEqual(@as(u32, bytes.len), value.capacity);
    try std.testing.expectEqual(@as(u32, envelope.envelope_byte_size + 4), value.encoded_size);
    for (bytes[value.encoded_size..]) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }

    bytes[value.encoded_size] = 1;
    const crc_offset = envelope.envelope_byte_size - @sizeOf(u32);
    var hasher = std.hash.Crc32.init();
    hasher.update(bytes[0..crc_offset]);
    hasher.update(bytes[crc_offset + @sizeOf(u32) ..]);
    std.mem.writeInt(u32, bytes[crc_offset..][0..@sizeOf(u32)], hasher.final(), .little);
    try std.testing.expectError(error.NonZeroPadding, envelope.readEmbedded(&bytes, type_identity));
}

test "fullaz-db value envelope: mutable embedded editor finishes a dirty revision" {
    var bytes: [96]u8 = undefined;
    try envelope.formatEmbedded(&bytes, metadata, "value");

    var editor = try envelope.openEmbeddedMut(&bytes, type_identity);
    try std.testing.expectEqual(metadata, try editor.metadata());
    const payload = try editor.payloadMut();
    payload[0] = 'V';
    try editor.advanceRevision();
    try std.testing.expect(editor.isDirty());
    try std.testing.expectError(error.BadCrc, envelope.readEmbedded(&bytes, type_identity));

    try editor.finish();
    try std.testing.expect(!editor.isDirty());
    try std.testing.expectError(error.EditorInvalidated, editor.payloadMut());

    const value = try envelope.readEmbedded(&bytes, type_identity);
    try std.testing.expectEqual(metadata.revision + 1, value.metadata.revision);
    try std.testing.expectEqualSlices(u8, "Value", value.payload);
}

test "fullaz-db value envelope: mutable editor invalidation preserves dirty state" {
    var bytes: [80]u8 = undefined;
    try envelope.formatEmbedded(&bytes, metadata, "edit");

    var editor = try envelope.openEmbeddedMut(&bytes, type_identity);
    (try editor.payloadMut())[0] = 'E';
    editor.invalidate();
    try std.testing.expect(editor.isDirty());
    try std.testing.expectError(error.EditorInvalidated, editor.finish());
    try std.testing.expectError(error.BadCrc, envelope.readEmbedded(&bytes, type_identity));
}

test "fullaz-db value envelope: mutable editor rejects invalid envelopes and revision overflow" {
    var raw_bytes: [80]u8 = undefined;
    try envelope.formatRaw(&raw_bytes, metadata, "raw");
    try std.testing.expectError(
        error.IncorrectKind,
        envelope.openEmbeddedMut(&raw_bytes, type_identity),
    );

    const maximum_revision_metadata = envelope.Metadata{
        .registry_id = metadata.registry_id,
        .type_id = metadata.type_id,
        .type_version = metadata.type_version,
        .metadata_format_version = metadata.metadata_format_version,
        .instance_id = metadata.instance_id,
        .revision = std.math.maxInt(u64),
    };
    var bytes: [80]u8 = undefined;
    try envelope.formatEmbedded(&bytes, maximum_revision_metadata, "edit");
    var editor = try envelope.openEmbeddedMut(&bytes, type_identity);
    try std.testing.expectError(error.RevisionOverflow, editor.advanceRevision());
    try std.testing.expect(!editor.isDirty());
    editor.invalidate();
}
