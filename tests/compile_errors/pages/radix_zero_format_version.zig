const fullaz_db = @import("fullaz-db");

comptime {
    _ = fullaz_db.radix(.{
        .Key = u32,
        .value_size = 8,
        .format_version = 0,
    });
}
