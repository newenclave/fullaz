const std = @import("std");
const build_options = @import("build_options");

pub const verbose = build_options.verbose_tests;

pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (verbose) {
        std.debug.print(fmt, args);
    }
}
