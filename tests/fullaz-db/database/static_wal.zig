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

const SyncCounts = struct {
    device: usize = 0,
    log: usize = 0,
};

const CountingMemoryDevice = struct {
    const Self = @This();
    const Inner = fullaz.device.MemoryBlock(u32);

    pub const BlockId = Inner.BlockId;
    pub const Error = Inner.Error;
    pub const append_only_dense_block_ids = Inner.append_only_dense_block_ids;

    inner: Inner,
    counts: *SyncCounts,

    fn init(allocator: std.mem.Allocator, block_size: usize, counts: *SyncCounts) Error!Self {
        return .{
            .inner = try Inner.init(allocator, block_size),
            .counts = counts,
        };
    }

    pub fn deinit(self: *Self) void {
        self.inner.deinit();
    }

    pub fn isValidId(self: *const Self, page_id: BlockId) bool {
        return self.inner.isValidId(page_id);
    }

    pub fn isOpen(self: *const Self) bool {
        return self.inner.isOpen();
    }

    pub fn blockSize(self: *const Self) usize {
        return self.inner.blockSize();
    }

    pub fn blocksCount(self: *const Self) usize {
        return self.inner.blocksCount();
    }

    pub fn appendBlock(self: *Self) Error!BlockId {
        return self.inner.appendBlock();
    }

    pub fn truncateBlocks(self: *Self, count: usize) Error!void {
        return self.inner.truncateBlocks(count);
    }

    pub fn readBlock(self: *const Self, page_id: BlockId, bytes: []u8) Error!void {
        return self.inner.readBlock(page_id, bytes);
    }

    pub fn writeBlock(self: *Self, page_id: BlockId, bytes: []u8) Error!void {
        return self.inner.writeBlock(page_id, bytes);
    }

    pub fn sync(self: *Self) Error!void {
        self.counts.device += 1;
        return self.inner.sync();
    }
};

const CountingMemoryLog = struct {
    const Self = @This();
    const Inner = fullaz.device.MemoryLog(u32);

    pub const Error = Inner.Error;
    pub const Offset = Inner.Offset;

    inner: Inner,
    counts: *SyncCounts,

    fn init(allocator: std.mem.Allocator, counts: *SyncCounts) Error!Self {
        return .{
            .inner = try Inner.init(allocator),
            .counts = counts,
        };
    }

    pub fn deinit(self: *Self) void {
        self.inner.deinit();
    }

    pub fn append(self: *Self, bytes: []const u8) Error!void {
        return self.inner.append(bytes);
    }

    pub fn sync(self: *Self) Error!void {
        self.counts.log += 1;
        return self.inner.sync();
    }

    pub fn reset(self: *Self) Error!void {
        return self.inner.reset();
    }

    pub fn truncate(self: *Self, end: Offset) Error!void {
        return self.inner.truncate(end);
    }

    pub fn size(self: *const Self) Offset {
        return self.inner.size();
    }

    pub fn readAt(self: *const Self, offset: Offset, bytes: []u8) Error!void {
        return self.inner.readAt(offset, bytes);
    }
};

test "fullaz-db: WAL static database syncs each file once per commit" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 });
    const Database = fullaz_db.StaticDatabaseWithWal(
        Schema,
        CountingMemoryDevice,
        CountingMemoryLog,
    );
    var counts = SyncCounts{};
    var database = try Database.format(
        std.testing.allocator,
        try CountingMemoryDevice.init(std.testing.allocator, 1024, &counts),
        try CountingMemoryLog.init(std.testing.allocator, &counts),
        .{ .image_id = [_]u8{3} ** 16, .components = .{} },
    );
    defer database.deinit();
    counts = .{};

    var transaction = try database.begin();
    try transaction.commit();

    try std.testing.expectEqual(@as(usize, 1), counts.device);
    try std.testing.expectEqual(@as(usize, 1), counts.log);
}

test "fullaz-db: WAL dynamic database defers sync until commit" {
    const Database = fullaz_db.DynamicDatabaseWithWal(
        CountingMemoryDevice,
        CountingMemoryLog,
    );
    var counts = SyncCounts{};
    var database = try Database.format(
        std.testing.allocator,
        try CountingMemoryDevice.init(std.testing.allocator, 1024, &counts),
        try CountingMemoryLog.init(std.testing.allocator, &counts),
        .{ .image_id = [_]u8{4} ** 16 },
    );
    defer database.deinit();
    counts = .{};

    var transaction = try database.begin();
    try std.testing.expectEqual(@as(usize, 0), counts.device);
    try std.testing.expectEqual(@as(usize, 0), counts.log);
    try transaction.commit();

    try std.testing.expectEqual(@as(usize, 1), counts.device);
    try std.testing.expectEqual(@as(usize, 1), counts.log);
}

test "fullaz-db: WAL static database reopens chainStore metadata" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add(
        "blob",
        fullaz_db.chainStore(.{}),
    );
    const Device = fullaz.device.FileBlock(u32);
    const Log = fullaz.device.FileLog(u32);
    const Database = fullaz_db.StaticDatabaseWithWal(Schema, Device, Log);
    const io = std.testing.io;
    const image_path = ".zig-cache/static_chain_store_wal.img";
    const log_path = ".zig-cache/static_chain_store_wal.log";
    const options: Database.InitOptions = .{
        .image_id = [_]u8{12} ** 16,
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
        var transaction = try database.begin();
        try transaction.get("blob").append("wal bytes");
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
        var output: [16]u8 = undefined;
        const blob = database.getConst("blob");
        try std.testing.expectEqual(@as(u64, 9), try blob.size());
        try std.testing.expectEqual(@as(usize, 9), try blob.readAt(0, &output));
        try std.testing.expectEqualStrings("wal bytes", output[0..9]);

        var transaction = try database.begin();
        defer transaction.deinit();
        try transaction.get("blob").append(" again");
        try transaction.commit();

        try std.testing.expectEqual(@as(u64, 15), try blob.size());
        try std.testing.expectEqual(@as(usize, 15), try blob.readAt(0, &output));
        try std.testing.expectEqualStrings("wal bytes again", output[0..15]);
    }
}

test "fullaz-db: WAL static database reopens weightedSequence metadata" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add(
        "sequence",
        fullaz_db.weightedSequence(.{ .maximum_chunk_size = 3 }),
    );
    const Device = fullaz.device.FileBlock(u32);
    const Log = fullaz.device.FileLog(u32);
    const Database = fullaz_db.StaticDatabaseWithWal(Schema, Device, Log);
    const io = std.testing.io;
    const image_path = ".zig-cache/static_weighted_sequence_wal.img";
    const log_path = ".zig-cache/static_weighted_sequence_wal.log";
    const options: Database.InitOptions = .{
        .image_id = [_]u8{14} ** 16,
        .components = .{ .sequence = .{} },
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
        var transaction = try database.begin();
        const sequence = transaction.get("sequence");
        try sequence.append("abcdef");
        try sequence.erase(1, 4);
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
        var output: [16]u8 = undefined;
        const sequence = database.getConst("sequence");
        try std.testing.expectEqual(@as(u64, 2), try sequence.size());
        try std.testing.expectEqual(@as(usize, 2), try sequence.readAt(0, &output));
        try std.testing.expectEqualStrings("af", output[0..2]);
    }
}

test "fullaz-db: WAL static database reopens SlotHeap metadata" {
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
    const Log = fullaz.device.FileLog(u32);
    const Database = fullaz_db.StaticDatabaseWithWal(Schema, Device, Log);
    const io = std.testing.io;
    const image_path = ".zig-cache/static_slot_heap_wal.img";
    const log_path = ".zig-cache/static_slot_heap_wal.log";
    const options: Database.InitOptions = .{
        .image_id = [_]u8{5} ** 16,
        .components = .{ .heap = .{} },
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
        var transaction = try database.begin();
        try transaction.get("heap").push("0002", "two");
        try transaction.get("heap").push("0001", "one");
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
        try std.testing.expectEqual(@as(u64, 2), try database.getConst("heap").count());
    }
}

test "fullaz-db: WAL static database persists BPT and validates WAL identity" {
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
    const Log = fullaz.device.FileLog(u32);
    const Database = fullaz_db.StaticDatabaseWithWal(Schema, Device, Log);
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

test "fullaz-db: WAL static database recovers a committed WAL page" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 });
    const Device = fullaz.device.FileBlock(u32);
    const Log = fullaz.device.FileLog(u32);
    const Database = fullaz_db.StaticDatabaseWithWal(Schema, Device, Log);
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
            .{ .image_id = options.image_id, .schema_digest = fullaz_db.schemaFingerprint(Schema) },
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

test "fullaz-db: WAL static database ignores an uncommitted WAL tail" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 });
    const Device = fullaz.device.FileBlock(u32);
    const Log = fullaz.device.FileLog(u32);
    const Database = fullaz_db.StaticDatabaseWithWal(Schema, Device, Log);
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
            .{ .image_id = options.image_id, .schema_digest = fullaz_db.schemaFingerprint(Schema) },
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

test "fullaz-db: WAL static database format rejects a nonempty log" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 });
    const Device = fullaz.device.MemoryBlock(u32);
    const Log = fullaz.device.MemoryLog(u32);
    const Database = fullaz_db.StaticDatabaseWithWal(Schema, Device, Log);
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
