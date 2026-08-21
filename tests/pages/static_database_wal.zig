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

test "Pages: WAL static database persists BPT and validates WAL identity" {
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
    const Log = fullaz.device.FileLog(u32);
    const Database = fullaz.pages.StaticDatabaseWithWal(Schema, Device, Log);
    const io = std.testing.io;
    const image_path = ".zig-cache/static_database_wal.img";
    const log_path = ".zig-cache/static_database_wal.log";
    const options: Database.InitOptions = .{
        .image_id = [_]u8{9} ** 16,
        .components = .{ .index = .{} },
    };
    prep(io, image_path);
    prep(io, log_path);
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, log_path) catch {};

    {
        var database = try Database.format(
            std.testing.allocator,
            try Device.create(io, image_path, 512),
            try Log.create(io, log_path),
            options,
        );
        defer database.deinit();
        const diagnostics = database.diagnostics();
        try std.testing.expectEqual(@as(usize, 512), diagnostics.page_size);
        try std.testing.expectEqual(@as(usize, 1), diagnostics.page_count);
        try std.testing.expect(diagnostics.wal_enabled);
        var transaction = try database.begin();
        try std.testing.expect(try transaction.get("index").insert("key", "value"));
        try transaction.commit();
    }

    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, image_path, 512),
            try Log.open(io, log_path),
            options,
        );
        defer database.deinit();
        const iterator = try database.getConst("index").find("key");
        try std.testing.expect(iterator != null);
        var owned_iterator = iterator.?;
        defer owned_iterator.deinit();
        try std.testing.expectEqualStrings("value", (try owned_iterator.get()).?.value);
    }

    var bad_options = options;
    bad_options.image_id = [_]u8{8} ** 16;
    try std.testing.expectError(
        error.WalIdentityMismatch,
        Database.open(
            std.testing.allocator,
            try Device.open(io, image_path, 512),
            try Log.open(io, log_path),
            bad_options,
        ),
    );
}

test "Pages: WAL static database recovers a committed WAL page" {
    const Schema = fullaz.pages.Schema(.{ .page_id = u32 });
    const Device = fullaz.device.FileBlock(u32);
    const Log = fullaz.device.FileLog(u32);
    const Database = fullaz.pages.StaticDatabaseWithWal(Schema, Device, Log);
    const WalT = Database.WalType;
    const io = std.testing.io;
    const image_path = ".zig-cache/static_database_wal_recovery.img";
    const log_path = ".zig-cache/static_database_wal_recovery.log";
    const options: Database.InitOptions = .{ .image_id = [_]u8{4} ** 16, .components = .{} };
    prep(io, image_path);
    prep(io, log_path);
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, log_path) catch {};

    {
        var database = try Database.format(
            std.testing.allocator,
            try Device.create(io, image_path, 512),
            try Log.create(io, log_path),
            options,
        );
        database.deinit();
    }
    {
        var log = try Log.open(io, log_path);
        defer log.deinit();
        var wal = try WalT.initWithIdentity(
            std.testing.allocator,
            &log,
            512,
            .{ .image_id = options.image_id, .schema_digest = fullaz.pages.schemaFingerprint(Schema) },
        );
        defer wal.deinit();
        var page: [512]u8 = undefined;
        var device = try Device.open(io, image_path, 512);
        defer device.deinit();
        try device.readBlock(0, &page);
        try wal.appendPage(0, &page);
        try wal.sealCommit(1);
    }
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, image_path, 512),
            try Log.open(io, log_path),
            options,
        );
        defer database.deinit();
    }
    var log = try Log.open(io, log_path);
    defer log.deinit();
    // Recovery checkpoints committed records but preserves the identity header.
    try std.testing.expectEqual(@as(u32, WalT.log_header_len), log.size());
}

test "Pages: WAL static database ignores an uncommitted WAL tail" {
    const Schema = fullaz.pages.Schema(.{ .page_id = u32 });
    const Device = fullaz.device.FileBlock(u32);
    const Log = fullaz.device.FileLog(u32);
    const Database = fullaz.pages.StaticDatabaseWithWal(Schema, Device, Log);
    const WalT = Database.WalType;
    const io = std.testing.io;
    const image_path = ".zig-cache/static_database_wal_uncommitted.img";
    const log_path = ".zig-cache/static_database_wal_uncommitted.log";
    const options: Database.InitOptions = .{ .image_id = [_]u8{13} ** 16, .components = .{} };
    prep(io, image_path);
    prep(io, log_path);
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, log_path) catch {};

    {
        var database = try Database.format(
            std.testing.allocator,
            try Device.create(io, image_path, 512),
            try Log.create(io, log_path),
            options,
        );
        database.deinit();
    }
    {
        var log = try Log.open(io, log_path);
        defer log.deinit();
        var wal = try WalT.initWithIdentity(
            std.testing.allocator,
            &log,
            512,
            .{ .image_id = options.image_id, .schema_digest = fullaz.pages.schemaFingerprint(Schema) },
        );
        defer wal.deinit();
        var page: [512]u8 = undefined;
        var device = try Device.open(io, image_path, 512);
        defer device.deinit();
        try device.readBlock(0, &page);
        try wal.appendPage(0, &page);
    }
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, image_path, 512),
            try Log.open(io, log_path),
            options,
        );
        database.deinit();
    }
    var log = try Log.open(io, log_path);
    defer log.deinit();
    try std.testing.expectEqual(@as(u32, WalT.log_header_len), log.size());
}

test "Pages: WAL static database format rejects a nonempty log" {
    const Schema = fullaz.pages.Schema(.{ .page_id = u32 });
    const Device = fullaz.device.MemoryBlock(u32);
    const Log = fullaz.device.MemoryLog(u32);
    const Database = fullaz.pages.StaticDatabaseWithWal(Schema, Device, Log);
    var device = try Device.init(std.testing.allocator, 512);
    defer device.deinit();
    var log = try Log.init(std.testing.allocator);
    defer log.deinit();
    try log.append("stale");
    try std.testing.expectError(
        error.LogNotEmpty,
        Database.format(
            std.testing.allocator,
            device,
            log,
            .{ .image_id = [_]u8{14} ** 16, .components = .{} },
        ),
    );
}
