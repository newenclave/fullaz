const std = @import("std");
const metadata_page = @import("fullaz-db").file.component_metadata_page;

const state = metadata_page.State{
    .component_id = 42,
    .metadata_format_version = 1,
};

test "fullaz-db component metadata page: round-trips its identity and payload" {
    var page = [_]u8{0} ** 512;
    try metadata_page.format(&page, state, "metadata");

    const view = try metadata_page.read(&page, state);
    try std.testing.expectEqual(state.component_id, view.state.component_id);
    try std.testing.expectEqual(state.metadata_format_version, view.state.metadata_format_version);
    try std.testing.expectEqualStrings("metadata", view.payload);
}

test "fullaz-db component metadata page: rejects a bad identity, CRC, and short page" {
    var page = [_]u8{0} ** 512;
    try metadata_page.format(&page, state, "metadata");

    try std.testing.expectError(
        error.IdentityMismatch,
        metadata_page.read(&page, .{
            .component_id = 43,
            .metadata_format_version = 1,
        }),
    );

    page[metadata_page.envelope_byte_size] ^= 1;
    try std.testing.expectError(error.BadComponentMetadataPage, metadata_page.read(&page, state));

    var short_page = [_]u8{0} ** (metadata_page.envelope_byte_size - 1);
    try std.testing.expectError(
        error.BadComponentMetadataPage,
        metadata_page.format(&short_page, state, ""),
    );
}
