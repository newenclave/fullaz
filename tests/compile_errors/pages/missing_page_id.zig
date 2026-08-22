const pages = @import("fullaz-db");
const Options = struct {};

comptime {
    _ = pages.Schema(Options{});
}
