const pages = @import("fullaz").pages;

comptime {
    _ = pages.bpt(.{
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 64,
        .maximum_value_size = 128,
    });
}
