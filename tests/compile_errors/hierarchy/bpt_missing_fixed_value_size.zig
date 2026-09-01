const std = @import("std");
const fullaz_db = @import("fullaz-db");

fn compare(_: void, _: []const u8, _: []const u8) std.math.Order {
    return .eq;
}

const BptDescriptor = fullaz_db.bpt(.{
    .compare = compare,
    .CompareContext = void,
    .comparator_id = 1,
    .maximum_key_size = 32,
    .maximum_value_size = 96,
});

comptime {
    _ = fullaz_db.Hierarchy(.{
        .registry_id = 1,
        .types = &.{.{
            .tag = "folder",
            .type_id = 1,
            .type_version = 1,
            .metadata_format_version = 1,
            .descriptor = BptDescriptor,
            .allowed_child_type_ids = &.{},
        }},
    });
}
