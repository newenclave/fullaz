const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

fn compare(_: void, left: []const u8, right: []const u8) fullaz.core.algorithm.Order {
    return switch (std.mem.order(u8, left, right)) {
        .lt => .lt,
        .eq => .eq,
        .gt => .gt,
    };
}

fn slotCompare(_: void, left: []const u8, right: []const u8) std.math.Order {
    return std.mem.order(u8, left, right);
}

fn prep(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

test "fullaz-db: static database reopens chainStore metadata" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add(
        "blob",
        fullaz_db.chainStore(.{}),
    );
    const Device = fullaz.device.FileBlock(u32);
    const Database = fullaz_db.StaticDatabase(Schema, Device);
    const io = std.testing.io;
    const path = ".zig-cache/static_chain_store.img";
    const options: Database.InitOptions = .{
        .image_id = [_]u8{11} ** 16,
        .components = .{ .blob = .{} },
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
        try transaction.get("blob").append("persistent bytes");
        try transaction.commit();
    }
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, path, 512),
            options,
        );
        defer database.deinit();
        var output: [32]u8 = undefined;
        const blob = database.getConst("blob");
        try std.testing.expectEqual(@as(u64, 16), try blob.size());
        try std.testing.expectEqual(@as(usize, 16), try blob.readAt(0, &output));
        try std.testing.expectEqualStrings("persistent bytes", output[0..16]);
    }
}

test "fullaz-db: static database reopens weightedSequence metadata" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add(
        "sequence",
        fullaz_db.weightedSequence(.{ .maximum_chunk_size = 3 }),
    );
    const Device = fullaz.device.FileBlock(u32);
    const Database = fullaz_db.StaticDatabase(Schema, Device);
    const io = std.testing.io;
    const path = ".zig-cache/static_weighted_sequence.img";
    const options: Database.InitOptions = .{
        .image_id = [_]u8{13} ** 16,
        .components = .{ .sequence = .{} },
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
        const sequence = transaction.get("sequence");
        try sequence.append("abcdef");
        try sequence.replace(2, 3, "XYZ");
        try transaction.commit();
    }
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, path, 512),
            options,
        );
        defer database.deinit();
        var output: [16]u8 = undefined;
        const sequence = database.getConst("sequence");
        try std.testing.expectEqual(@as(u64, 6), try sequence.size());
        try std.testing.expectEqual(@as(usize, 6), try sequence.readAt(0, &output));
        try std.testing.expectEqualStrings("abXYZf", output[0..6]);
    }
}

const Collector = struct {
    count: usize = 0,
    sum: u32 = 0,

    fn callback(self: *Collector, _: anytype, value: []const u8) void {
        self.count += 1;
        self.sum += std.mem.readInt(u32, value[0..4], .little);
    }
};

test "fullaz-db: static database reopens SlotHeap metadata" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add(
        "heap",
        fullaz_db.slotHeap(.{
            .compare = slotCompare,
            .CompareContext = void,
            .comparator_id = 1,
            .maximum_key_size = 4,
            .maximum_value_size = 16,
        }),
    );
    const Device = fullaz.device.FileBlock(u32);
    const Database = fullaz_db.StaticDatabase(Schema, Device);
    const io = std.testing.io;
    const path = ".zig-cache/static_slot_heap.img";
    const options: Database.InitOptions = .{
        .image_id = [_]u8{6} ** 16,
        .components = .{ .heap = .{} },
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
        try transaction.get("heap").push("0002", "two");
        try transaction.get("heap").push("0001", "one");
        try transaction.commit();
    }
    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, path, 512),
            options,
        );
        defer database.deinit();
        try std.testing.expectEqual(@as(u64, 2), try database.getConst("heap").count());
        var transaction = try database.begin();
        var top = try transaction.get("heap").top();
        defer top.deinit();
        try std.testing.expectEqualSlices(u8, "0001", try top.key());
        try transaction.rollback();
    }
}

test "fullaz-db: static database formats, opens, and persists reclaimed BPT pages" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add(
        "index",
        fullaz_db.bpt(.{
            .compare = compare,
            .CompareContext = void,
            .comparator_id = 1,
            .maximum_key_size = 32,
            .maximum_value_size = 32,
        }),
    );
    const Device = fullaz.device.FileBlock(u32);
    const Database = fullaz_db.StaticDatabase(Schema, Device);
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
        const diagnostics = database.diagnostics();
        try std.testing.expectEqual(@as(usize, 512), diagnostics.page_size);
        try std.testing.expectEqual(@as(usize, 1), diagnostics.page_count);
        try std.testing.expect(!diagnostics.wal_enabled);

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

test "fullaz-db: static database reopens an R-tree root" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add(
        "spatial",
        fullaz_db.rtree(.{
            .Coord = i64,
            .dimensions = 2,
            .maximum_entries = 4,
            .maximum_value_size = 4,
        }),
    );
    const Device = fullaz.device.FileBlock(u32);
    const Database = fullaz_db.StaticDatabase(Schema, Device);
    const Box = Schema.trait("spatial").Binding(Database.BackendType).Proxy.BoundingBox;
    const io = std.testing.io;
    const path = ".zig-cache/static_database_rtree.img";
    const options: Database.InitOptions = .{
        .image_id = [_]u8{6} ** 16,
        .components = .{ .spatial = .{} },
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
        var value: [4]u8 = undefined;
        std.mem.writeInt(u32, &value, 42, .little);
        var transaction = try database.begin();
        try transaction.get("spatial").insert(Box.initWith(.{ 2, 2 }, .{ 4, 4 }), &value);
        try transaction.commit();
    }

    {
        var database = try Database.open(
            std.testing.allocator,
            try Device.open(io, path, 512),
            options,
        );
        defer database.deinit();
        var collector = Collector{};
        try database.getConst("spatial").search(
            Box.initWith(.{ 0, 0 }, .{ 10, 10 }),
            &collector,
            Collector.callback,
        );
        try std.testing.expectEqual(@as(usize, 1), collector.count);
        try std.testing.expectEqual(@as(u32, 42), collector.sum);
    }
}

test "fullaz-db: static database rejects a different image identity" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 });
    const Device = fullaz.device.FileBlock(u32);
    const Database = fullaz_db.StaticDatabase(Schema, Device);
    const io = std.testing.io;
    const path = ".zig-cache/static_database_identity.img";
    const options: Database.InitOptions = .{ .image_id = [_]u8{3} ** 16, .components = .{} };
    prep(io, path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        var database = try Database.format(
            std.testing.allocator,
            try Device.create(io, path, 512),
            options,
        );
        database.deinit();
    }

    var wrong_options = options;
    wrong_options.image_id = [_]u8{4} ** 16;
    try std.testing.expectError(
        error.IdentityMismatch,
        Database.open(
            std.testing.allocator,
            try Device.open(io, path, 512),
            wrong_options,
        ),
    );
}

test "fullaz-db: static database requires a nonzero image identity" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 });
    const Device = fullaz.device.MemoryBlock(u32);
    const Database = fullaz_db.StaticDatabase(Schema, Device);
    var device = try Device.init(std.testing.allocator, 512);
    defer device.deinit();
    try std.testing.expectError(
        error.InvalidImageId,
        Database.format(std.testing.allocator, device, .{}),
    );
}

test "fullaz-db: static database rejects a dirty image" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 });
    const Device = fullaz.device.FileBlock(u32);
    const Database = fullaz_db.StaticDatabase(Schema, Device);
    const io = std.testing.io;
    const path = ".zig-cache/static_database_dirty.img";
    const options: Database.InitOptions = .{ .image_id = [_]u8{5} ** 16, .components = .{} };
    prep(io, path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        var database = try Database.format(
            std.testing.allocator,
            try Device.create(io, path, 512),
            options,
        );
        database.deinit();
    }
    {
        var device = try Device.open(io, path, 512);
        defer device.deinit();
        var page: [512]u8 = undefined;
        try device.readBlock(0, &page);
        const identity: Database.SuperblockType.Identity = .{
            .image_id = options.image_id,
            .schema_digest = fullaz_db.schemaFingerprint(Schema),
        };
        const storage = try Database.SuperblockType.read(&page, page.len, identity);
        try Database.SuperblockType.format(
            &page,
            page.len,
            storage.page_count.get(),
            identity,
            storage.metadata,
            false,
        );
        try device.writeBlock(0, &page);
        try device.sync();
    }
    try std.testing.expectError(
        error.DirtyDatabase,
        Database.open(
            std.testing.allocator,
            try Device.open(io, path, 512),
            options,
        ),
    );
}

test "fullaz-db: static database rejects a cyclic persistent free list" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add(
        "index",
        fullaz_db.bpt(.{
            .compare = compare,
            .CompareContext = void,
            .comparator_id = 1,
            .maximum_key_size = 32,
            .maximum_value_size = 32,
        }),
    );
    const Device = fullaz.device.FileBlock(u32);
    const Database = fullaz_db.StaticDatabase(Schema, Device);
    const FreedView = fullaz.page.freed.View(u32, .little, false);
    const io = std.testing.io;
    const path = ".zig-cache/static_database_free_cycle.img";
    const options: Database.InitOptions = .{
        .image_id = [_]u8{11} ** 16,
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
        var insert_transaction = try database.begin();
        try std.testing.expect(try insert_transaction.get("index").insert("key", "value"));
        try insert_transaction.commit();
        var remove_transaction = try database.begin();
        try std.testing.expect(try remove_transaction.get("index").remove("key"));
        try remove_transaction.commit();
    }
    {
        var device = try Device.open(io, path, 512);
        defer device.deinit();
        var superblock_page: [512]u8 = undefined;
        try device.readBlock(0, &superblock_page);
        const identity: Database.SuperblockType.Identity = .{
            .image_id = options.image_id,
            .schema_digest = fullaz_db.schemaFingerprint(Schema),
        };
        const storage = try Database.SuperblockType.read(&superblock_page, superblock_page.len, identity);
        const free_root = storage.metadata.free_root.get();
        try std.testing.expect(free_root != 0);
        var freed_page: [512]u8 = undefined;
        try device.readBlock(free_root, &freed_page);
        var view = FreedView.init(&freed_page);
        view.formatPage(free_root);
        try device.writeBlock(free_root, &freed_page);
        try device.sync();
    }
    try std.testing.expectError(
        error.BadFreeList,
        Database.open(
            std.testing.allocator,
            try Device.open(io, path, 512),
            options,
        ),
    );
}

test "fullaz-db: static database rejects an out-of-range component root" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add(
        "index",
        fullaz_db.bpt(.{
            .compare = compare,
            .CompareContext = void,
            .comparator_id = 1,
            .maximum_key_size = 32,
            .maximum_value_size = 32,
        }),
    );
    const Device = fullaz.device.FileBlock(u32);
    const Database = fullaz_db.StaticDatabase(Schema, Device);
    const io = std.testing.io;
    const path = ".zig-cache/static_database_bad_root.img";
    const options: Database.InitOptions = .{
        .image_id = [_]u8{12} ** 16,
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
    }
    {
        var device = try Device.open(io, path, 512);
        defer device.deinit();
        var page: [512]u8 = undefined;
        try device.readBlock(0, &page);
        const identity: Database.SuperblockType.Identity = .{
            .image_id = options.image_id,
            .schema_digest = fullaz_db.schemaFingerprint(Schema),
        };
        const storage = try Database.SuperblockType.read(&page, page.len, identity);
        var metadata = storage.metadata;
        metadata.index.root.set(999);
        try Database.SuperblockType.format(
            &page,
            page.len,
            storage.page_count.get(),
            identity,
            metadata,
            true,
        );
        try device.writeBlock(0, &page);
        try device.sync();
    }
    try std.testing.expectError(
        error.BadMetadata,
        Database.open(
            std.testing.allocator,
            try Device.open(io, path, 512),
            options,
        ),
    );
}
