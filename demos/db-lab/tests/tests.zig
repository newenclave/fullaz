const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");
const lab = @import("db_lab");

fn countFreePages(database: anytype) !usize {
    const cache = database.cache();
    const page_count = cache.pageCount();
    var count: usize = 0;
    var index: usize = 0;
    while (index < page_count) : (index += 1) {
        const page_id: u32 = std.math.cast(u32, index) orelse return error.PageIdTooLarge;
        if (try cache.isFree(page_id)) {
            count += 1;
        }
    }
    return count;
}

test "db-lab creates embedded tables, updates values, and reclaims removed entries" {
    const Database = fullaz_db.MemoryDatabase(lab.Schema);
    var database = try Database.init(std.testing.allocator, .{
        .page_size = 1024,
        .cache_frames = 32,
        .components = .{ .catalog = .{ .owner_0 = .{} } },
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
        try Device.init(std.testing.allocator, 1024),
        try Log.init(std.testing.allocator),
        .{
            .image_id = [_]u8{0xD1} ** 16,
            .components = .{ .catalog = .{ .owner_0 = .{} } },
        },
    );
    defer database.deinit();

    try lab.createTable(&database, "events");
    try lab.put(&database, "events", "0001", "created");
    var rows = try lab.snapshot(&database, std.testing.allocator);
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), rows.items.len);
    try std.testing.expectEqualStrings("events", rows.items[0].table[0..rows.items[0].table_len]);
    try std.testing.expect(try lab.remove(&database, "events", "0001"));
    try std.testing.expect(database.diagnostics().virtual_page_count >= 1);
}

test "db-lab marks then sweeps a disconnected table in dynamic WAL" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Log = fullaz.device.MemoryLog(u32);
    const Database = fullaz_db.DynamicSchemaDatabaseWithWal(lab.Schema, Device, Log);
    var database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 1024),
        try Log.init(std.testing.allocator),
        .{
            .image_id = [_]u8{0xD3} ** 16,
            .cache_frames = 32,
            .components = .{ .catalog = .{ .owner_0 = .{} } },
        },
    );
    defer database.deinit();

    var committed_planets: usize = 0;
    try lab.generateExamplesWithCount(&database, std.testing.allocator, 64, &committed_planets);
    try std.testing.expectEqual(@as(usize, 64), committed_planets);
    try std.testing.expect(try lab.deleteTable(&database, "planets"));

    var rows = try lab.snapshot(&database, std.testing.allocator);
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 5), rows.items.len);

    try database.startGarbageCollection();
    var phase = try database.garbageCollectionPhase();
    while (phase != .sweeping) {
        try std.testing.expect(phase == .preparing or phase == .marking);
        _ = try database.stepGarbageCollection(32);
        phase = try database.garbageCollectionPhase();
    }

    const free_pages_before_sweep = try countFreePages(&database);
    var status = try database.stepGarbageCollection(32);
    while (status != .complete) {
        status = try database.stepGarbageCollection(32);
    }
    try std.testing.expect((try countFreePages(&database)) > free_pages_before_sweep + 10);
}

test "db-lab marks then sweeps a disconnected table in static WAL" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Log = fullaz.device.MemoryLog(u32);
    const Database = fullaz_db.StaticDatabaseWithWal(lab.Schema, Device, Log);
    var database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 1024),
        try Log.init(std.testing.allocator),
        .{
            .image_id = [_]u8{0xD4} ** 16,
            .cache_frames = 32,
            .components = .{ .catalog = .{ .owner_0 = .{} } },
        },
    );
    defer database.deinit();

    var committed_planets: usize = 0;
    try lab.generateExamplesWithCount(&database, std.testing.allocator, 64, &committed_planets);
    try std.testing.expect(try lab.deleteTable(&database, "planets"));

    var rows = try lab.snapshot(&database, std.testing.allocator);
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 5), rows.items.len);
    try database.startGarbageCollection();
    while (try database.stepGarbageCollection(32) != .complete) {}
    try std.testing.expect((try countFreePages(&database)) > 10);
}

test "db-lab marks then sweeps a disconnected table in virtual static WAL" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Log = fullaz.device.MemoryLog(u32);
    const Database = fullaz_db.VirtualStaticDatabaseWithWal(lab.Schema, Device, Log);
    var database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 1024),
        try Log.init(std.testing.allocator),
        .{
            .image_id = [_]u8{0xD5} ** 16,
            .cache_frames = 32,
            .components = .{ .catalog = .{ .owner_0 = .{} } },
        },
    );
    defer database.deinit();

    var committed_planets: usize = 0;
    try lab.generateExamplesWithCount(&database, std.testing.allocator, 64, &committed_planets);
    try std.testing.expect(try lab.deleteTable(&database, "planets"));

    var rows = try lab.snapshot(&database, std.testing.allocator);
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 5), rows.items.len);
    try database.startGarbageCollection();
    while (try database.stepGarbageCollection(32) != .complete) {}
    try std.testing.expect((try countFreePages(&database)) > 10);
}

test "db-lab generates a bounded deterministic planet catalog in batches" {
    const Database = fullaz_db.MemoryDatabase(lab.Schema);
    var database = try Database.init(std.testing.allocator, .{
        .page_size = 1024,
        .cache_frames = 32,
        .components = .{ .catalog = .{ .owner_0 = .{} } },
    });
    defer database.deinit();

    var committed_planets: usize = 99;
    try std.testing.expectError(
        error.InvalidExampleCount,
        lab.generateExamplesWithCount(
            &database,
            std.testing.allocator,
            lab.minimum_planet_count - 1,
            &committed_planets,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), committed_planets);

    try lab.generateExamplesWithCount(
        &database,
        std.testing.allocator,
        lab.default_planet_count,
        &committed_planets,
    );
    try std.testing.expectEqual(lab.default_planet_count, committed_planets);
    var rows = try lab.snapshot(&database, std.testing.allocator);
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(lab.default_planet_count + 5, rows.items.len);
    try std.testing.expectEqualStrings("events", rows.items[0].table[0..rows.items[0].table_len]);
    try std.testing.expectEqualStrings("planet-000", rows.items[3].key[0..rows.items[3].key_len]);
    try std.testing.expect(rows.items[3].value_len > 0);
    for (rows.items) |row| {
        try std.testing.expect(row.table_len <= 32);
        try std.testing.expect(row.key_len <= 32);
        try std.testing.expect(row.value_len <= 64);
    }
    try std.testing.expect(database.diagnostics().device_page_count > 32);
    try std.testing.expectError(
        error.TableAlreadyExists,
        lab.generateExamplesWithCount(
            &database,
            std.testing.allocator,
            lab.default_planet_count,
            &committed_planets,
        ),
    );
}

test "db-lab can replace a populated virtual database" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Log = fullaz.device.MemoryLog(u32);
    const Database = fullaz_db.VirtualStaticDatabaseWithWal(lab.Schema, Device, Log);
    const options: Database.InitOptions = .{
        .image_id = [_]u8{0xD2} ** 16,
        .cache_frames = 32,
        .components = .{ .catalog = .{ .owner_0 = .{} } },
    };
    var database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 1024),
        try Log.init(std.testing.allocator),
        options,
    );
    try lab.createTable(&database, "users");
    try lab.put(&database, "users", "ada", "first");
    database.deinit();

    database = try Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 1024),
        try Log.init(std.testing.allocator),
        options,
    );
    defer database.deinit();
    var rows = try lab.snapshot(&database, std.testing.allocator);
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), rows.items.len);
}
