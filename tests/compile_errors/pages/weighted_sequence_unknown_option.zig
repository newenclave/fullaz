const pages = @import("fullaz-db");

comptime {
    _ = pages.weightedSequence(.{ .page_kind = 1 });
}
