const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

fn compare(
    _: void,
    _: []const u8,
    _: []const u8,
) error{ComparisonFailed}!fullaz.core.algorithm.Order {
    return error.ComparisonFailed;
}

comptime {
    _ = fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 64,
        .maximum_value_size = 128,
    });
}
