const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

fn compare(_: void, left: []const u8, right: []const u8) std.math.Order {
    return std.mem.order(u8, left, right);
}

const Schema = fullaz_db.Schema(.{ .page_id = u32 })
    .add("index", fullaz_db.bpt(.{
    .compare = compare,
    .CompareContext = void,
    .comparator_id = 1,
    .maximum_key_size = 64,
    .maximum_value_size = 256,
}));
const Db = fullaz_db.MemoryDatabase(Schema);

pub fn main() !void {
    var db = try Db.init(std.heap.page_allocator, .{
        .page_size = 4096,
        .cache_frames = 16,
    });
    defer db.deinit();

    var transaction = try db.begin();
    defer transaction.deinit();
    _ = try transaction.get("index").insert("hello", "world");
    try transaction.commit();

    var found = (try db.getConst("index").find("hello")).?;
    defer found.deinit();
    const entry = (try found.get()).?;
    std.debug.print("{s}: {s}\n", .{ entry.key, entry.value });
}
