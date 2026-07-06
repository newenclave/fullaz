const std = @import("std");
const fullaz = @import("fullaz");
const zigline = @import("zigline");

pub fn main() !void {
    // Scaffold entry point for the fsx CLI (a filesystem stored inside one file).
    // For now this only verifies the build wiring: both fullaz and zigline
    // import and resolve cleanly. The real CLI (open/format + REPL) lands later.
    _ = fullaz;
    _ = zigline;

    std.debug.print("fsx: filesystem-in-a-file demo (scaffold)\n", .{});
    std.debug.print("usage: fsx <image> [--format]   (commands coming soon)\n", .{});
}
