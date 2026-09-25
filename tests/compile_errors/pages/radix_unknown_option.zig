const fullaz_db = @import("fullaz-db");

comptime {
    _ = fullaz_db.radix(.{
        .Key = u32,
        .value_size = 8,
        .leaf_page_kind = 7,
    });
}
