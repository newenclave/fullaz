const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

fn prep(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

test "fullaz-db: radix virtual WAL persists logical pages across reopen" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add(
        "index",
        fullaz_db.radix(.{ .Key = u64, .value_size = 8 }),
    );
    const Device = fullaz.device.FileBlock(u64);
    const Log = fullaz.device.FileLog(u64);
    const Database = fullaz_db.VirtualStaticDatabaseWithWal(Schema, Device, Log);
    const io = std.testing.io;
    const image_path = ".zig-cache/virtual_static_radix_wal.img";
    const log_path = ".zig-cache/virtual_static_radix_wal.log";
    const options: Database.InitOptions = .{
        .image_id = [_]u8{103} ** 16,
        .components = .{ .index = .{} },
    };
    prep(io, image_path);
    prep(io, log_path);
    defer std.Io.Dir.cwd().deleteFile(io, image_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, log_path) catch {};

    const key: u64 = 0x0102030405060708;
    var logical_page_count: usize = undefined;
    {
        var database = try Database.format(
            std.testing.allocator,
            try Device.create(io, image_path, 512),
            try Log.create(io, log_path),
            options,
        );
        defer database.deinit();
        var transaction = try database.begin();
        defer transaction.deinit();
        try transaction.get("index").set(key, "virt-wal");
        try transaction.commit();

        const diagnostics = database.diagnostics();
        logical_page_count = diagnostics.virtual_page_count;
        try std.testing.expect(logical_page_count > 1);
        try std.testing.expect(diagnostics.physical_page_count > logical_page_count);
    }
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, image_path, 512),
            try Log.open(io, log_path),
            options,
        );
        defer database.deinit();
        try std.testing.expectEqual(logical_page_count, database.diagnostics().virtual_page_count);
        var entry = (try database.getConst("index").find(key)).?;
        defer entry.deinit();
        const result = try entry.get();
        try std.testing.expectEqual(key, result.key);
        try std.testing.expectEqualSlices(u8, "virt-wal", result.value);
    }
}

test "fullaz-db: virtual static WAL database keeps logical roots across reopen" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add(
        "blob",
        fullaz_db.chainStore(.{}),
    );
    const Device = fullaz.device.FileBlock(u64);
    const Log = fullaz.device.FileLog(u64);
    const Database = fullaz_db.VirtualStaticDatabaseWithWal(Schema, Device, Log);
    try std.testing.expectEqual(@as(u16, 3), Database.SuperblockType.version);
    const io = std.testing.io;
    const image_path = ".zig-cache/virtual_static_chain_store.img";
    const log_path = ".zig-cache/virtual_static_chain_store.log";
    const options: Database.InitOptions = .{
        .image_id = [_]u8{21} ** 16,
        .components = .{ .blob = .{} },
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
        try std.testing.expect(diagnostics.physical_page_count >= 3);
        try std.testing.expectEqual(@as(usize, 1), diagnostics.virtual_page_count);

        var transaction = try database.begin();
        try transaction.get("blob").append("virtual bytes");
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
        var output: [32]u8 = undefined;
        const blob = database.getConst("blob");
        try std.testing.expectEqual(@as(u64, 13), try blob.size());
        try std.testing.expectEqual(@as(usize, 13), try blob.readAt(0, &output));
        try std.testing.expectEqualStrings("virtual bytes", output[0..13]);
    }
    {
        var wrong_options = options;
        wrong_options.image_id[0] ^= 1;
        try std.testing.expectError(
            error.WalIdentityMismatch,
            Database.open(
                std.testing.allocator,
                try Device.open(io, image_path, 512),
                try Log.open(io, log_path),
                wrong_options,
            ),
        );
    }
}
