const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");
const lab = @import("db_lab");

test "db-lab creates namespaces, updates values, and reclaims removed entries" {
    const Database = fullaz_db.MemoryDatabase(lab.Schema);
    var database = try Database.init(std.testing.allocator, .{
        .page_size = 512,
        .cache_frames = 32,
    });
    defer database.deinit();

    try lab.createTable(&database, "users");
    try lab.put(&database, "users", "ada", "first value");
    try lab.put(&database, "users", "ada", "updated value");
    try lab.put(&database, "users", "linus", "second value");

    var rows = try lab.snapshot(&database, std.testing.allocator);
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), rows.items.len);
    try std.testing.expectEqualStrings("users", rows.items[0].table[0..rows.items[0].table_len]);
    try std.testing.expectEqualStrings("ada", rows.items[0].key[0..rows.items[0].key_len]);
    try std.testing.expectEqualStrings("updated value", rows.items[0].value[0..rows.items[0].value_len]);

    try std.testing.expect(try lab.remove(&database, "users", "ada"));
    try std.testing.expectError(error.TableNotFound, lab.put(&database, "missing", "key", "value"));
}

test "db-lab runs the same catalog operations through the virtual WAL backend" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Log = fullaz.device.MemoryLog(u32);
    const Database = fullaz_db.VirtualStaticDatabaseWithWal(lab.Schema, Device, Log);
    var database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 512),
        try Log.init(std.testing.allocator),
        .{
            .image_id = [_]u8{0xD1} ** 16,
            .components = .{ .tables = .{}, .values = .{} },
        },
    );
    defer database.deinit();

    try lab.createTable(&database, "events");
    try lab.put(&database, "events", "0001", "created");
    try std.testing.expect(try lab.remove(&database, "events", "0001"));
    try std.testing.expect(database.diagnostics().virtual_page_count >= 1);
}

test "db-lab can replace a populated virtual database" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Log = fullaz.device.MemoryLog(u32);
    const Database = fullaz_db.VirtualStaticDatabaseWithWal(lab.Schema, Device, Log);
    const options: Database.InitOptions = .{
        .image_id = [_]u8{0xD2} ** 16,
        .components = .{ .tables = .{}, .values = .{} },
    };
    var database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 512),
        try Log.init(std.testing.allocator),
        options,
    );
    try lab.createTable(&database, "users");
    try lab.put(&database, "users", "ada", "first");
    database.deinit();

    database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 512),
        try Log.init(std.testing.allocator),
        options,
    );
    defer database.deinit();
    var rows = try lab.snapshot(&database, std.testing.allocator);
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), rows.items.len);
}
