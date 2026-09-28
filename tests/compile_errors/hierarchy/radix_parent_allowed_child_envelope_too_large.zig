const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

fn compare(_: void, _: []const u8, _: []const u8) std.math.Order {
    return .eq;
}

const Parent = fullaz_db.radix(.{
    .Key = u32,
    .value_size = 71,
});
const Child = fullaz_db.radix(.{
    .Key = u16,
    .value_size = 8,
});
const Hierarchy = fullaz_db.Hierarchy(.{
    .registry_id = 1,
    .types = &.{
        .{
            .tag = "branch",
            .type_id = 1,
            .type_version = 1,
            .metadata_format_version = 1,
            .descriptor = Parent,
            .allowed_child_type_ids = &.{2},
        },
        .{
            .tag = "child",
            .type_id = 2,
            .type_version = 1,
            .metadata_format_version = 1,
            .descriptor = Child,
            .allowed_child_type_ids = &.{},
        },
    },
});
const Owner = fullaz_db.bpt(.{
    .compare = compare,
    .CompareContext = void,
    .comparator_id = 1,
    .maximum_key_size = 16,
    .maximum_value_size = 72,
    .fixed_value_size = 72,
});
const Store = fullaz_db.hierarchyStore(Hierarchy, .{ .owners = &.{.{
    .tag = "nodes",
    .owner_id = 1,
    .descriptor = Owner,
    .allowed_type_ids = &.{1},
}} });
const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add("tree", Store);
const Database = fullaz_db.DynamicSchemaDatabase(Schema, fullaz.device.MemoryBlock(u32));

comptime {
    _ = Database;
}
