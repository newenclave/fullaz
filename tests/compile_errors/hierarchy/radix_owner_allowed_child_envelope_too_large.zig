const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

const Child = fullaz_db.radix(.{
    .Key = u16,
    .value_size = 8,
});
const Hierarchy = fullaz_db.Hierarchy(.{
    .registry_id = 1,
    .types = &.{.{
        .tag = "child",
        .type_id = 1,
        .type_version = 1,
        .metadata_format_version = 1,
        .descriptor = Child,
        .allowed_child_type_ids = &.{},
    }},
});
const Store = fullaz_db.hierarchyStore(Hierarchy, .{ .owners = &.{.{
    .tag = "numbers",
    .owner_id = 1,
    .descriptor = fullaz_db.radix(.{
        .Key = u32,
        .value_size = 71,
    }),
    .allowed_type_ids = &.{1},
}} });
const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add("tree", Store);
const Database = fullaz_db.DynamicSchemaDatabase(Schema, fullaz.device.MemoryBlock(u32));

comptime {
    _ = Database;
}
