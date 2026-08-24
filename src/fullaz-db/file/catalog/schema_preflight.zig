const std = @import("std");
const catalog_record = @import("record.zig");
const schema_fingerprint = @import("../../component/fingerprint.zig");

pub const Error = error{
    UnknownComponent,
    KindMismatch,
    FormatVersionMismatch,
    PageKindCountMismatch,
    SettingsMismatch,
};

/// Validates one catalog record against the compiled schema and returns its
/// schema-field index. Dynamic page-kind bases intentionally are not compared.
pub fn validateRecord(comptime SchemaT: type, record: catalog_record.View) Error!usize {
    inline for (SchemaT.fields, 0..) |field, index| {
        if (std.mem.eql(u8, record.name, field.name)) {
            const Trait = field.descriptor.Trait;
            if (!std.mem.eql(u8, record.kind_name, Trait.kind_name)) {
                return error.KindMismatch;
            }
            if (record.component_format_version != Trait.format_version) {
                return error.FormatVersionMismatch;
            }
            if (record.page_kind_count != Trait.page_kind_count) {
                return error.PageKindCountMismatch;
            }
            if (!std.mem.eql(
                u8,
                &record.settings_fingerprint,
                &schema_fingerprint.componentDigest(Trait),
            )) {
                return error.SettingsMismatch;
            }
            return index;
        }
    }
    return error.UnknownComponent;
}
