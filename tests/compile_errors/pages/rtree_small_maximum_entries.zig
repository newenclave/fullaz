const fullaz = @import("fullaz");

comptime {
    _ = fullaz.pages.rtree(.{
        .Coord = i64,
        .dimensions = 2,
        .maximum_entries = 3,
        .maximum_value_size = 16,
    });
}
