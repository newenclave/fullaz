const pages = @import("fullaz").pages;

comptime {
    _ = pages.slotHeap(.{
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 4,
        .maximum_value_size = 4,
    });
}
