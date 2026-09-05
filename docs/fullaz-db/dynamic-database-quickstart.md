# Dynamic Schema WAL Database Quick Start

Use `DynamicSchemaDatabaseWithWal` when a typed schema also needs durable
catalog records for its components. Component names still come from the
compiled `Schema`; this is not SQL with runtime table names.

This is an advanced backend. Its WAL is not currently bound to the image
identity, so your deployment must keep each image with its exact WAL.

Use this `src/main.zig` in a project that depends on `fullaz`.

```zig
const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

const image_path = "catalog.img";
const wal_path = "catalog.wal";
const page_size = 4096;

const Schema = fullaz_db.Schema(.{ .page_id = u32 })
    .add("notes", fullaz_db.chainStore(.{}));
const Device = fullaz.device.FileBlock(u32);
const Log = fullaz.device.FileLog(u32);
const Database = fullaz_db.DynamicSchemaDatabaseWithWal(Schema, Device, Log);

const options: Database.InitOptions = .{
    .image_id = [_]u8{0xB1} ** 16,
    .cache_frames = 64,
    .components = .{ .notes = .{} },
};

fn format(allocator: std.mem.Allocator, io: std.Io) !void {
    const device = try Device.create(io, image_path, page_size);
    const log = try Log.create(io, wal_path);
    var database = try Database.format(allocator, device, log, options);
    defer database.deinit();

    var transaction = try database.begin();
    defer transaction.deinit();
    try transaction.get("notes").append("catalog-backed note\n");
    try transaction.commit();
}

fn openAndRead(allocator: std.mem.Allocator, io: std.Io) !void {
    const device = try Device.open(io, image_path, page_size);
    const log = try Log.open(io, wal_path);
    var database = try Database.open(allocator, device, log, options);
    defer database.deinit();

    var output: [128]u8 = undefined;
    const count = try database.getConst("notes").readAt(0, &output);
    std.debug.print("{s}", .{output[0..count]});
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const command = args.next() orelse return error.InvalidArguments;

    if (std.mem.eql(u8, command, "format")) {
        try format(init.gpa, init.io);
    } else if (std.mem.eql(u8, command, "open")) {
        try openAndRead(init.gpa, init.io);
    } else {
        return error.InvalidArguments;
    }
}
```

Run `zig build run -- format` only when you explicitly want to create new
storage. `FileBlock.create` and `FileLog.create` truncate existing paths.

Run `zig build run -- open` later. It prints:

```text
catalog-backed note
```

Adding a field to `Schema` is valid when you format a new image. Opening an old
catalog with that new compiled schema returns `MissingComponent`. Use an
explicit catalog migration when an existing image needs a new component.

## Next

Raw catalog operations and migration procedures are advanced topics outside
this local guide.
