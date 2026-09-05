# Static WAL Database Quick Start

Use `StaticDatabaseWithWal` when one compiled schema owns one persistent image.
The WAL records committed page changes before they reach the image.

This example stores notes in a `ChainStore`. Put it in `src/main.zig` in a Zig
project that depends on `fullaz`.

```zig
const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

const image_path = "app.img";
const wal_path = "app.wal";
const page_size = 4096;

const Schema = fullaz_db.Schema(.{ .page_id = u32 })
    .add("notes", fullaz_db.chainStore(.{}));
const Device = fullaz.device.FileBlock(u32);
const Log = fullaz.device.FileLog(u32);
const Database = fullaz_db.StaticDatabaseWithWal(Schema, Device, Log);

const options: Database.InitOptions = .{
    .image_id = [_]u8{0xA1} ** 16,
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
    try transaction.get("notes").append("first durable note\n");
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

## Step 1: Create The Database

Run this command once:

```sh
zig build run -- format
```

`format` calls `FileBlock.create` and `FileLog.create`. Both calls truncate an
existing file. Do not use this command for normal startup.

## Step 2: Open It Later

Run this command after the image exists:

```sh
zig build run -- open
```

It prints:

```text
first durable note
```

Keep the page size, image ID, schema, component settings, image, and WAL the
same when you open an image. A schema change creates a different image format.

## Next

Read the local [persistence and recovery guide](getting-started/06-persistence-and-recovery.md).
