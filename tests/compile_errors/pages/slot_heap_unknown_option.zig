const std = @import("std");
const pages = @import("fullaz-db");

fn compare(_: void, left: []const u8, right: []const u8) std.math.Order {
    return std.mem.order(u8, left, right);
}

comptime {
    _ = pages.slotHeap(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 4,
        .maximum_value_size = 4,
        .leaf_page_kind = 1,
    });
}
