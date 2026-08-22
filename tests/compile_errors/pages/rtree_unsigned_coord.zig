const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

comptime {
    _ = fullaz_db.rtree(.{
        .Coord = u64,
        .dimensions = 2,
        .maximum_entries = 4,
        .maximum_value_size = 16,
    });
}
