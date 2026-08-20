const fullaz = @import("fullaz");

fn compare(
    _: void,
    _: []const u8,
    _: []const u8,
) error{ComparisonFailed}!fullaz.core.algorithm.Order {
    return error.ComparisonFailed;
}

comptime {
    _ = fullaz.pages.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 64,
        .maximum_value_size = 128,
    });
}
