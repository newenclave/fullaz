const std = @import("std");
const component = @import("../../component/component.zig");
const dynamic_metadata = @import("dynamic.zig");
const tagged = @import("../tagged_fields.zig");

pub const Error = dynamic_metadata.Error;

/// Restores one known component's runtime metadata from its tagged payload.
pub fn restore(
    comptime BindingT: type,
    runtime: *BindingT.Runtime,
    payload: []const u8,
    page_count: usize,
) Error!void {
    const MetadataT = BindingT.DynamicMetadata;
    comptime component.assertDynamicMetadata(BindingT, MetadataT);
    try tagged.validateOwnedFields(payload, MetadataT.known_tags, MetadataT.repeated_tags);
    try MetadataT.restore(runtime, payload, page_count);
}

/// Rewrites known fields and retains every unowned field byte-for-byte.
/// `payload_scratch` backs the returned slice; `destination` is only used as a
/// capacity-checked copy target so callers can write directly to a metadata page.
pub fn rewrite(
    comptime BindingT: type,
    runtime: *const BindingT.Runtime,
    destination: []u8,
    payload_scratch: []u8,
    previous_payload: []const u8,
) Error![]const u8 {
    const MetadataT = BindingT.DynamicMetadata;
    comptime component.assertDynamicMetadata(BindingT, MetadataT);
    try tagged.validateOwnedFields(
        previous_payload,
        MetadataT.known_tags,
        MetadataT.repeated_tags,
    );

    var writer = tagged.Writer.init(payload_scratch);
    try tagged.copyUnknownFieldsAfterValidation(&writer, previous_payload, MetadataT.known_tags);
    try MetadataT.encodeKnown(runtime, &writer);
    if (writer.used().len > destination.len) {
        return error.BufferTooSmall;
    }
    @memcpy(destination[0..writer.used().len], writer.used());
    return destination[0..writer.used().len];
}

/// Migrates an old payload into `BindingT.DynamicMetadata.format_version`.
/// The optional hook emits target known fields and should use
/// `dynamic_metadata.copyForwardUnknownFields` for forward tagged fields.
pub fn migrate(
    comptime BindingT: type,
    source_format_version: u32,
    source_payload: []const u8,
    destination: []u8,
    payload_scratch: []u8,
) Error![]const u8 {
    const MetadataT = BindingT.DynamicMetadata;
    comptime component.assertDynamicMetadata(BindingT, MetadataT);
    if (source_format_version == MetadataT.format_version) {
        return error.UnsupportedMigration;
    }
    if (comptime !@hasDecl(MetadataT, "migrate")) {
        return error.UnsupportedMigration;
    }

    var writer = tagged.Writer.init(payload_scratch);
    try MetadataT.migrate(source_format_version, source_payload, &writer);
    if (writer.used().len > destination.len) {
        return error.BufferTooSmall;
    }
    @memcpy(destination[0..writer.used().len], writer.used());
    return destination[0..writer.used().len];
}
