const std = @import("std");
const fullaz = @import("fullaz");

pub fn main() !void {
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
}
