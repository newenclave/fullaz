const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

const CompareContext = struct { direction: bool };

fn compare(_: CompareContext, _: []const u8, _: []const u8) fullaz.core.algorithm.Order {
    return .eq;
}

const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add(
    "index",
    fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = CompareContext,
        .comparator_id = 1,
        .maximum_key_size = 8,
        .maximum_value_size = 8,
    }),
);

const Database = fullaz_db.StaticDatabase(Schema, fullaz.device.MemoryBlock(u32));

comptime {
    _ = Database;
}
