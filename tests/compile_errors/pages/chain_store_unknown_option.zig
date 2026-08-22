const pages = @import("fullaz").pages;

comptime {
    _ = pages.chainStore(.{ .chunk_page_kind = 1 });
}
