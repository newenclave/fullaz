const pages = @import("fullaz").pages;

comptime {
    _ = pages.weightedSequence(.{ .page_kind = 1 });
}
