const fullaz_db = @import("fullaz-db");

comptime {
    _ = fullaz_db.radix(.{
        .Key = i32,
        .value_size = 8,
    });
}
