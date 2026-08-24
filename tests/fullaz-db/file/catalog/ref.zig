const std = @import("std");
const catalog_ref = @import("fullaz-db").file.catalog_ref;

test "fullaz-db CatalogRef: round-trips its fixed little-endian representation" {
    const ref = try catalog_ref.CatalogRef.init(0x0102_0304_0506_0708, 0x090a, 0x0b0c_0d0e);
    var bytes: [catalog_ref.encoded_size]u8 = undefined;
    try ref.encode(&bytes);

    try std.testing.expectEqualSlices(
        u8,
        &.{
            0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
            0x0a, 0x09, 0x00, 0x00, 0x0e, 0x0d, 0x0c, 0x0b,
        },
        &bytes,
    );

    const decoded = try catalog_ref.CatalogRef.decode(&bytes);
    try std.testing.expectEqual(ref.getPageId(), decoded.getPageId());
    try std.testing.expectEqual(ref.getSlotId(), decoded.getSlotId());
    try std.testing.expectEqual(ref.getRecordRevision(), decoded.getRecordRevision());
}

test "fullaz-db CatalogRef: rejects null, zero revision, reserved bytes, and wrong size" {
    try std.testing.expectError(error.BadCatalogRef, catalog_ref.CatalogRef.init(0, 0, 1));
    try std.testing.expectError(error.BadCatalogRef, catalog_ref.CatalogRef.init(1, 0, 0));

    var bytes: [catalog_ref.encoded_size]u8 = undefined;
    try (try catalog_ref.CatalogRef.init(1, 0, 1)).encode(&bytes);
    bytes[10] = 1;
    try std.testing.expectError(error.BadCatalogRef, catalog_ref.CatalogRef.decode(&bytes));
    try std.testing.expectError(error.BadCatalogRef, catalog_ref.CatalogRef.decode(bytes[0..15]));

    var short_bytes: [catalog_ref.encoded_size - 1]u8 = undefined;
    try std.testing.expectError(
        error.BufferTooSmall,
        (try catalog_ref.CatalogRef.init(1, 0, 1)).encode(&short_bytes),
    );
}
