const std = @import("std");
const tagged = @import("../tagged_fields.zig");

pub const Error = tagged.Error || error{
    BadMetadata,
    UnsupportedMigration,
};

pub fn appendU64(writer: *tagged.Writer, tag: u16, value: u64) Error!void {
    var bytes: [@sizeOf(u64)]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    try writer.append(tag, 0, &bytes);
}

pub fn readU64(field: tagged.Field) Error!u64 {
    if (field.flags != 0 or field.value.len != @sizeOf(u64)) {
        return error.BadMetadata;
    }
    return std.mem.readInt(u64, field.value[0..@sizeOf(u64)], .little);
}

/// Copies fields the target metadata format does not own, including their
/// headers and values, byte-for-byte. Migration hooks should call this after
/// emitting their target known fields to preserve forward extensions.
pub fn copyForwardUnknownFields(
    writer: *tagged.Writer,
    source_payload: []const u8,
    target_known_tags: []const u16,
) Error!void {
    try tagged.copyUnknownFieldsAfterValidation(writer, source_payload, target_known_tags);
}

pub fn decodeOptionalPageId(
    comptime PageIdT: type,
    value: u64,
    page_count: usize,
) Error!?PageIdT {
    if (value == 0) {
        return null;
    }
    const page_id = std.math.cast(PageIdT, value) orelse return error.BadMetadata;
    const page_index = std.math.cast(usize, page_id) orelse return error.BadMetadata;
    if (page_index >= page_count) {
        return error.BadMetadata;
    }
    return page_id;
}
