const std = @import("std");
const fullaz = @import("fullaz");
const zigline = @import("zigline");

// Aggregator for the fsx test suite. New fsx test files get pulled in here with
// `_ = @import("<name>.zig");` as the project grows.

test "fsx scaffold: fullaz and zigline modules import" {
    _ = fullaz;
    _ = zigline;
}

test {
    _ = @import("constants.zig");
    _ = @import("superblock.zig");
    _ = @import("inode.zig");
    _ = @import("path.zig");
    _ = @import("dir.zig");
    _ = @import("fs.zig");
    _ = @import("fs_paths.zig");
    _ = @import("fs_files.zig");
}
