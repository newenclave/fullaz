# Virtual Static WAL Database Quick Start

`VirtualStaticDatabaseWithWal` uses logical virtual page IDs in components and
maps them to physical device page IDs. Use it when stable logical page IDs are
part of your storage design. Its component API is otherwise the same as static
WAL.

Use this `src/main.zig` in a project that depends on `fullaz`.

```zig
const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

const image_path = "virtual.img";
const wal_path = "virtual.wal";
const page_size = 4096;

const Schema = fullaz_db.Schema(.{ .page_id = u32 })
    .add("notes", fullaz_db.chainStore(.{}));
const Device = fullaz.device.FileBlock(u64);
const Log = fullaz.device.FileLog(u64);
const Database = fullaz_db.VirtualStaticDatabaseWithWal(Schema, Device, Log);

const options: Database.InitOptions = .{
    .image_id = [_]u8{0xC1} ** 16,
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
    try transaction.get("notes").append("stable logical pages\n");
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
storage. `FileBlock.create` and `FileLog.create` truncate existing paths. Run
`zig build run -- open` for normal later startup.

The schema uses logical `u32` page IDs. The device uses physical `u64` page
IDs. Fixed-width physical IDs are recommended for portable persistent files.
Use physical `u32` for a wasm32 application unless a wider physical-ID path is
tested for that target.

The virtual image format is not compatible with `StaticDatabaseWithWal`. Use
this factory for both formatting and opening one virtual image.

## Next

Virtual page-map and physical-free-list internals are outside this local guide.
