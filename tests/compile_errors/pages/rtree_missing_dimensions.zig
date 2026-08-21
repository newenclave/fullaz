const fullaz = @import("fullaz");

comptime {
    _ = fullaz.pages.rtree(.{
        .Coord = i64,
        .maximum_entries = 4,
        .maximum_value_size = 16,
    });
}
