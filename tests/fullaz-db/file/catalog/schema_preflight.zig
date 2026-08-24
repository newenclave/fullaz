const std = @import("std");
const fullaz_db = @import("fullaz-db");

const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add("blob", fullaz_db.chainStore(.{}));

fn record() fullaz_db.file.catalog_record.Record {
    const Trait = Schema.trait("blob");
    return .{
        .component_id = 1,
        .revision = 1,
        .name = "blob",
        .kind_name = Trait.kind_name,
        .component_format_version = Trait.format_version,
        .metadata_format_version = 1,
        .page_kind_base = 0x0100,
        .page_kind_count = Trait.page_kind_count,
        .metadata_root_pid = 1,
        .settings_fingerprint = fullaz_db.componentFingerprint(Trait),
        .dependency_ids = &.{},
    };
}

fn validate(value: fullaz_db.file.catalog_record.Record) !usize {
    var bytes: [512]u8 = undefined;
    var scratch: [512]u8 = undefined;
    try fullaz_db.file.catalog_record.format(&bytes, &scratch, value, &.{});
    const value_view = try fullaz_db.file.catalog_record.read(
        bytes[0..try fullaz_db.file.catalog_record.encodedByteSize(&bytes)],
    );
    return fullaz_db.file.schema_preflight.validateRecord(Schema, value_view);
}

test "fullaz-db schema preflight: validates durable component identity" {
    try std.testing.expectEqual(@as(usize, 0), try validate(record()));

    var wrong_kind = record();
    wrong_kind.kind_name = "other";
    try std.testing.expectError(error.KindMismatch, validate(wrong_kind));

    var wrong_settings = record();
    wrong_settings.settings_fingerprint[0] = 1;
    try std.testing.expectError(error.SettingsMismatch, validate(wrong_settings));
}
