const fullaz = @import("fullaz");

comptime {
    _ = fullaz.pages.rtree(.{
        .Coord = i64,
        .dimensions = 0,
        .maximum_entries = 4,
        .maximum_value_size = 16,
    });
}
