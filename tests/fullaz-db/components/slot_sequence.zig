const std = @import("std");
const fullaz_db = @import("fullaz-db");

const Schema = fullaz_db.Schema(.{ .page_id = u32 })
    .add("list", fullaz_db.slotList(.{ .maximum_value_size = 32 }))
    .add("queue", fullaz_db.slotQueue(.{ .maximum_value_size = 32 }))
    .add("stack", fullaz_db.slotStack(.{ .maximum_value_size = 32 }));
const Database = fullaz_db.MemoryDatabase(Schema);

fn expectValues(iterator_value: anytype, expected: []const []const u8) !void {
    var iterator = iterator_value;
    defer iterator.deinit();
    for (expected) |value| {
        try std.testing.expectEqualStrings(value, (try iterator.next()).?);
    }
    try std.testing.expectEqual(@as(?[]const u8, null), try iterator.next());
}

test "fullaz-db: slot sequences preserve their public order" {
    var database = try Database.init(std.testing.allocator, .{
        .page_size = 128,
        .cache_frames = 16,
    });
    defer database.deinit();

    {
        var transaction = try database.begin();
        defer transaction.deinit();

        const list = transaction.get("list");
        try list.append("a");
        try list.append("b");
        try list.append("c");

        const queue = transaction.get("queue");
        try queue.enqueue("a");
        try queue.enqueue("b");
        try queue.enqueue("c");

        const stack = transaction.get("stack");
        try stack.push("a");
        try stack.push("b");
        try stack.push("c");

        try transaction.commit();
    }

    try expectValues((try database.getConst("list").iterator()).?, &.{ "a", "b", "c" });
    try expectValues((try database.getConst("queue").iterator()).?, &.{ "a", "b", "c" });
    try expectValues((try database.getConst("stack").iterator()).?, &.{ "c", "b", "a" });

    {
        var queue_front = try database.getConst("queue").front();
        defer queue_front.deinit();
        try std.testing.expectEqualStrings("a", try queue_front.value());
    }
    {
        var stack_top = try database.getConst("stack").top();
        defer stack_top.deinit();
        try std.testing.expectEqualStrings("c", try stack_top.value());
    }
}

test "fullaz-db: slot sequence tombstones are logical until cleanup" {
    var database = try Database.init(std.testing.allocator, .{
        .page_size = 128,
        .cache_frames = 16,
    });
    defer database.deinit();

    {
        var transaction = try database.begin();
        defer transaction.deinit();
        const list = transaction.get("list");
        try list.append("a");
        try list.append("b");
        try list.append("c");

        var iterator = (try list.iterator()).?;
        try std.testing.expectEqualStrings("a", (try iterator.next()).?);
        try iterator.markTombstone();
        iterator.deinit();

        try std.testing.expectEqual(@as(usize, 2), try list.size());
        try std.testing.expectEqual(@as(usize, 3), try list.elementsCount());
        try std.testing.expectEqual(@as(usize, 1), try list.tombstoneCount());
        try std.testing.expectEqual(@as(usize, 1), try list.removeTombstones());
        try std.testing.expectEqual(@as(usize, 2), try list.elementsCount());
        try std.testing.expectEqual(@as(usize, 0), try list.tombstoneCount());
        try transaction.commit();
    }

    try expectValues((try database.getConst("list").iterator()).?, &.{ "b", "c" });
}

test "fullaz-db: slot sequence mutations roll back" {
    var database = try Database.init(std.testing.allocator, .{
        .page_size = 128,
        .cache_frames = 16,
    });
    defer database.deinit();

    var transaction = try database.begin();
    const list = transaction.get("list");
    try list.append("discarded");
    try transaction.rollback();

    try std.testing.expect(try database.getConst("list").isEmpty());
    try std.testing.expectError(error.TransactionInactive, list.append("late"));
}

test "fullaz-db: queue and stack tombstones preserve FIFO and LIFO behavior" {
    var database = try Database.init(std.testing.allocator, .{
        .page_size = 128,
        .cache_frames = 16,
    });
    defer database.deinit();

    var transaction = try database.begin();
    defer transaction.deinit();
    const queue = transaction.get("queue");
    const stack = transaction.get("stack");
    for ([_][]const u8{ "a", "b", "c" }) |value| {
        try queue.enqueue(value);
        try stack.push(value);
    }

    var queue_iterator = (try queue.iterator()).?;
    try std.testing.expectEqualStrings("a", (try queue_iterator.next()).?);
    try queue_iterator.markTombstone();
    queue_iterator.deinit();

    var stack_iterator = (try stack.iterator()).?;
    try std.testing.expectEqualStrings("c", (try stack_iterator.next()).?);
    try stack_iterator.markTombstone();
    stack_iterator.deinit();

    {
        var front = try queue.front();
        defer front.deinit();
        try std.testing.expectEqualStrings("b", try front.value());
    }
    {
        var top = try stack.top();
        defer top.deinit();
        try std.testing.expectEqualStrings("b", try top.value());
    }

    try queue.dequeue();
    try stack.pop();
    try std.testing.expectEqual(@as(usize, 1), try queue.size());
    try std.testing.expectEqual(@as(usize, 1), try stack.size());
    try std.testing.expectEqual(@as(usize, 1), try queue.removeTombstones());
    try std.testing.expectEqual(@as(usize, 1), try stack.removeTombstones());
    try transaction.commit();

    try expectValues((try database.getConst("queue").iterator()).?, &.{"c"});
    try expectValues((try database.getConst("stack").iterator()).?, &.{"a"});
}

test "fullaz-db: slot sequence borrows gate structural mutation and commit" {
    var database = try Database.init(std.testing.allocator, .{
        .page_size = 128,
        .cache_frames = 16,
    });
    defer database.deinit();

    var transaction = try database.begin();
    const list = transaction.get("list");
    try std.testing.expectError(error.ValueTooLarge, list.append("a" ** 33));
    try list.append("value");

    var iterator = (try list.iterator()).?;
    _ = (try iterator.next()).?;
    try std.testing.expectError(error.IteratorActive, list.append("blocked"));
    try std.testing.expectError(error.IteratorActive, transaction.commit());

    var editor = (try iterator.editValue()).?;
    iterator.deinit();
    @memcpy(try editor.valueMut(), "VALUE");
    try std.testing.expectError(error.ValueEditorActive, transaction.commit());
    try editor.finish();
    try transaction.commit();

    try expectValues((try database.getConst("list").iterator()).?, &.{"VALUE"});
}

test "fullaz-db: slot sequences reopen with tombstones" {
    const fullaz = @import("fullaz");
    const Device = fullaz.device.FileBlock(u32);
    const StaticDatabase = fullaz_db.StaticDatabase(Schema, Device);
    const io = std.testing.io;
    const path = ".zig-cache/static_slot_sequences.img";
    const options: StaticDatabase.InitOptions = .{
        .image_id = [_]u8{0x5a} ** 16,
        .components = .{ .list = .{}, .queue = .{}, .stack = .{} },
    };
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        var database = try StaticDatabase.format(
            std.testing.allocator,
            try Device.create(io, path, 256),
            options,
        );
        defer database.deinit();

        var transaction = try database.begin();
        const list = transaction.get("list");
        try list.append("a");
        try list.append("b");
        var iterator = (try list.iterator()).?;
        _ = (try iterator.next()).?;
        try iterator.markTombstone();
        iterator.deinit();
        try transaction.get("queue").enqueue("queued");
        try transaction.get("stack").push("stacked");
        try transaction.commit();
    }
    {
        var database = try StaticDatabase.open(
            std.testing.allocator,
            try Device.open(io, path, 256),
            options,
        );
        defer database.deinit();

        const list = database.getConst("list");
        try std.testing.expectEqual(@as(usize, 1), try list.size());
        try std.testing.expectEqual(@as(usize, 2), try list.elementsCount());
        try std.testing.expectEqual(@as(usize, 1), try list.tombstoneCount());
        try expectValues((try list.iterator()).?, &.{"b"});

        var front = try database.getConst("queue").front();
        defer front.deinit();
        try std.testing.expectEqualStrings("queued", try front.value());
        var top = try database.getConst("stack").top();
        defer top.deinit();
        try std.testing.expectEqualStrings("stacked", try top.value());
    }
}
