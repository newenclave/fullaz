# First Memory Database

`MemoryDatabase` uses the same typed schema and component API as persistent
typed databases. Its pages disappear at `deinit`, so use it to test a data
model before adding files and recovery.

Replace `src/main.zig` with:

```zig
const std = @import("std");
const fullaz_db = @import("fullaz-db");

fn compare(_: void, left: []const u8, right: []const u8) std.math.Order {
    return std.mem.order(u8, left, right);
}

const Schema = fullaz_db.Schema(.{ .page_id = u32 })
    .add("users", fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 32,
        .maximum_value_size = 128,
    }))
    .add("audit", fullaz_db.chainStore(.{}));
const Database = fullaz_db.MemoryDatabase(Schema);

pub fn main() !void {
    var database = try Database.init(std.heap.page_allocator, .{
        .page_size = 4096,
        .cache_frames = 32,
    });
    defer database.deinit();

    var create = try database.begin();
    defer create.deinit();
    if (!try create.get("users").insert("ada", "Ada Lovelace")) {
        return error.UserAlreadyExists;
    }
    try create.get("audit").append("created ada\n");
    try create.commit();

    {
        var found = (try database.getConst("users").find("ada")).?;
        defer found.deinit();
        const entry = (try found.get()).?;
        std.debug.print("{s}: {s}\n", .{ entry.key, entry.value });
    }

    var update = try database.begin();
    defer update.deinit();
    if (!try update.get("users").update("ada", "Countess of Lovelace")) {
        return error.UserNotFound;
    }
    try update.commit();

    var cancelled = try database.begin();
    defer cancelled.deinit();
    _ = try cancelled.get("users").insert("temporary", "must disappear");
    try cancelled.rollback();
}
```

Run:

```sh
zig build run
```

Expected output:

```text
ada: Ada Lovelace
```

The same component operations work across typed backends, but factories can
have different constraints and options. This example uses `CompareContext = void`,
which is accepted by every typed persistent backend.

[Previous: Zig concepts](02-zig-concepts-used-by-fullaz-db.md) | [Next: choose a backend](04-choosing-a-backend.md)
