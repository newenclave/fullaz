const std = @import("std");
const fullaz = @import("fullaz");
const zigline = @import("zigline");

pub fn main() !void {
    _ = fullaz;
    _ = zigline;

    std.debug.print("fsx: filesystem-in-a-file demo (scaffold)\n", .{});
    std.debug.print("usage: fsx <image> [--format]   (commands coming soon)\n", .{});
}
