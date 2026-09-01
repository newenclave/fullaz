const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

fn compare(_: void, _: []const u8, _: []const u8) std.math.Order {
    return .eq;
}

const FolderDescriptor = fullaz_db.bpt(.{
    .compare = compare,
    .CompareContext = void,
    .comparator_id = 2,
    .maximum_key_size = 32,
    .maximum_value_size = 72,
    .fixed_value_size = 72,
});

const Hierarchy = fullaz_db.Hierarchy(.{
    .registry_id = 1,
    .types = &.{
        .{
            .tag = "folder",
            .type_id = 1,
            .type_version = 1,
            .metadata_format_version = 1,
            .descriptor = FolderDescriptor,
            .allowed_child_type_ids = &.{2},
        },
        .{
            .tag = "document",
            .type_id = 2,
            .type_version = 1,
            .metadata_format_version = 1,
            .descriptor = fullaz_db.chainStore(.{}),
            .allowed_child_type_ids = &.{},
        },
    },
});

const Owner = fullaz_db.hierarchyBpt(Hierarchy, fullaz_db.bpt(.{
    .compare = compare,
    .CompareContext = void,
    .comparator_id = 1,
    .maximum_key_size = 32,
    .maximum_value_size = 96,
    .fixed_value_size = 96,
}));
const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add("tree", Owner);
const Database = fullaz_db.DynamicSchemaDatabase(Schema, fullaz.device.MemoryBlock(u32));

comptime {
    _ = Database;
}
