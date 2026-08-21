const std = @import("std");
const fullaz = @import("fullaz");

fn compare(_: void, left: []const u8, right: []const u8) fullaz.core.algorithm.Order {
    return switch (std.mem.order(u8, left, right)) {
        .lt => .lt,
        .eq => .eq,
        .gt => .gt,
    };
}

fn prep(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

test "Pages: static database formats, opens, and persists reclaimed BPT pages" {
    const Schema = fullaz.pages.Schema(.{ .page_id = u32 }).add(
        "index",
        fullaz.pages.bpt(.{
            .compare = compare,
            .CompareContext = void,
            .comparator_id = 1,
            .maximum_key_size = 32,
            .maximum_value_size = 32,
        }),
    );
    const Device = fullaz.device.FileBlock(u32);
    const Database = fullaz.pages.StaticDatabase(Schema, Device);
    const io = std.testing.io;
    const path = ".zig-cache/static_database.img";
    const options: Database.InitOptions = .{
        .image_id = [_]u8{7} ** 16,
        .components = .{ .index = .{} },
    };
    prep(io, path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        var database = try Database.format(
            std.testing.allocator,
            try Device.create(io, path, 512),
            options,
        );
        defer database.deinit();

        var transaction = try database.begin();
        try std.testing.expect(try transaction.get("index").insert("key", "value"));
        try transaction.commit();

        var remove_transaction = try database.begin();
        try std.testing.expect(try remove_transaction.get("index").remove("key"));
        try remove_transaction.commit();

        var reuse_transaction = try database.begin();
        try std.testing.expect(try reuse_transaction.get("index").insert("next", "value"));
        try reuse_transaction.commit();
    }

    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, path, 512),
            options,
        );
        defer database.deinit();
        const iterator = try database.getConst("index").find("next");
        try std.testing.expect(iterator != null);
        var owned_iterator = iterator.?;
        defer owned_iterator.deinit();
        const result = (try owned_iterator.get()).?;
        try std.testing.expectEqualStrings("value", result.value);
    }
}
