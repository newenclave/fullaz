const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

fn compare(_: void, left: []const u8, right: []const u8) fullaz.core.algorithm.Order {
    return switch (std.mem.order(u8, left, right)) {
        .lt => .lt,
        .eq => .eq,
        .gt => .gt,
    };
}

comptime {
    _ = fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 64,
        .maximum_value_size = 128,
        .leaf_page_kind = 7,
    });
}
