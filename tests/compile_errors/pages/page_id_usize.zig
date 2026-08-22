const fullaz_db = @import("fullaz-db");

comptime {
    _ = fullaz_db.Schema(.{ .page_id = usize });
}
