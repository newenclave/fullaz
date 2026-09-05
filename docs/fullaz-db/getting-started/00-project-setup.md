# Create A Zig Project

This chapter creates an application that imports `fullaz` and `fullaz-db`. Use
Zig `0.16.0` or newer. Run every command in a terminal.

## 1. Create The Project

```sh
mkdir my-database
cd my-database
zig init
zig fetch --save=fullaz git+https://github.com/newenclave/fullaz.git
```

`zig fetch --save` adds the source dependency to `build.zig.zon`. Pin a reviewed
commit before shipping an application. This project is educational and its file
formats can change.

## 2. Expose The Modules

Replace the generated `build.zig` with:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const fullaz_dep = b.dependency("fullaz", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "my-database",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fullaz", .module = fullaz_dep.module("fullaz") },
                .{ .name = "fullaz-db", .module = fullaz_dep.module("fullaz-db") },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| {
        run.addArgs(args);
    }
    b.step("run", "Run the database example").dependOn(&run.step);
}
```

`fullaz` provides devices and low-level structures. `fullaz-db` provides the
schema, components, and database factories in this guide.

## 3. Verify Imports

Put this in `src/main.zig`:

```zig
const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

pub fn main() !void {
    _ = fullaz;
    _ = fullaz_db;
    std.debug.print("fullaz-db is connected\n", .{});
}
```

Run:

```sh
zig build
zig build run
```

Expected output:

```text
fullaz-db is connected
```

[Next: design a schema](01-pages-schemas-and-components.md)
