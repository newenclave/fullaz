const pages = @import("fullaz-db");

comptime {
    _ = pages.chainStore(.{ .chunk_page_kind = 1 });
}
