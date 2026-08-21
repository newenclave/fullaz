const fullaz = @import("fullaz");

comptime {
    _ = fullaz.pages.rtree(.{
        .dimensions = 2,
        .maximum_entries = 4,
        .maximum_value_size = 16,
    });
}
