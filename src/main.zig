const std = @import("std");
const fullaz = @import("fullaz");

fn compare(_: void, left: []const u8, right: []const u8) fullaz.core.algorithm.Order {
    return switch (std.mem.order(u8, left, right)) {
        .lt => .lt,
        .eq => .eq,
        .gt => .gt,
    };
}

const Schema = fullaz.pages.Schema(.{ .page_id = u32 })
    .add("index", fullaz.pages.bpt(.{
    .compare = compare,
    .CompareContext = void,
    .comparator_id = 1,
    .maximum_key_size = 64,
    .maximum_value_size = 256,
}));
const Db = fullaz.pages.MemoryDatabase(Schema);

pub fn main() !void {
    var db = try Db.init(std.heap.page_allocator, .{
        .page_size = 4096,
        .cache_frames = 16,
    });
    defer db.deinit();

    _ = try db.get("index").insert("hello", "world");
    var found = (try db.get("index").find("hello")).?;
    defer found.deinit();
    const entry = (try found.get()).?;
    std.debug.print("{s}: {s}\n", .{ entry.key, entry.value });
}
