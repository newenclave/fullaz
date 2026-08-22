const pages = @import("fullaz-db");

comptime {
    _ = pages.weightedSequence(.{ .maximum_chunk_size = 0 });
}
