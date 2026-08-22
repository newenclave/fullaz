const pages = @import("fullaz").pages;

comptime {
    _ = pages.weightedSequence(.{ .maximum_chunk_size = 0 });
}
