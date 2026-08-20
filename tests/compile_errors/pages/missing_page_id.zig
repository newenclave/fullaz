const pages = @import("fullaz").pages;
const Options = struct {};

comptime {
    _ = pages.Schema(Options{});
}
