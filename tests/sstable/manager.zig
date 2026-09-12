const std = @import("std");
const fullaz = @import("fullaz");

const sstable = fullaz.sstable;
const allocator = std.testing.allocator;
const Format = sstable.SstableFormatVersionedWithLsn(u64, u32, u32, u64, .little);
const Log = fullaz.device.MemoryLog(u64);
const Manager = sstable.SstableManager(Format, Log, compareBytes, void);

fn compareBytes(_: void, a: []const u8, b: []const u8) fullaz.core.algorithm.Order {
    return switch (std.mem.order(u8, a, b)) {
        .lt => .lt,
        .eq => .eq,
        .gt => .gt,
    };
}

fn table(
    table_id: Manager.TableId,
    min_lsn: u64,
    max_lsn: u64,
    smallest_key: []const u8,
    largest_key: []const u8,
) Manager.TableInfo {
    return .{
        .table_id = table_id,
        .file_size = 4096,
        .entry_count = 8,
        .keys_count = 3,
        .min_lsn = min_lsn,
        .max_lsn = max_lsn,
        .smallest_key = smallest_key,
        .largest_key = largest_key,
    };
}

test "SSTable manager creates empty metadata and persists global LSN ranges" {
    var log = try Log.init(allocator);
    defer log.deinit();

    {
        var manager = try Manager.create(allocator, &log, .{ .comparator_id = 42 }, {});
        defer manager.deinit();

        try std.testing.expectEqual(@as(u64, 0), manager.lastAssignedLsn());
        try std.testing.expectEqual(@as(u64, 0), manager.lastAssignedTableId());
        try std.testing.expectEqual(@as(usize, 0), manager.tables().len);
        try std.testing.expectEqual(log.size(), log.synced);

        try std.testing.expectEqual(@as(u64, 1), try manager.nextLsn());
        const reserved = try manager.reserveLsns(3);
        try std.testing.expectEqual(@as(u64, 2), reserved.first);
        try std.testing.expectEqual(@as(u64, 4), reserved.last);
        try std.testing.expectEqual(@as(u64, 4), manager.lastAssignedLsn());
        try std.testing.expectEqual(@as(u64, 1), try manager.nextTableId());
        const table_ids = try manager.reserveTableIds(3);
        try std.testing.expectEqual(@as(u64, 2), table_ids.first);
        try std.testing.expectEqual(@as(u64, 4), table_ids.last);
        try std.testing.expectEqual(@as(u64, 4), manager.lastAssignedTableId());
        try std.testing.expectError(error.InvalidLsnCount, manager.reserveLsns(0));
        try std.testing.expectError(error.InvalidTableIdCount, manager.reserveTableIds(0));
        try std.testing.expectError(error.NoChanges, manager.publish(.{}));
    }

    var reopened = try Manager.open(allocator, &log, .{ .comparator_id = 42 }, {});
    defer reopened.deinit();
    try std.testing.expectEqual(@as(u64, 4), reopened.lastAssignedLsn());
    try std.testing.expectEqual(@as(u64, 4), reopened.lastAssignedTableId());
    try std.testing.expectEqual(@as(usize, 0), reopened.tables().len);
}

test "SSTable manager publishes owned table metadata and atomic replacements" {
    var log = try Log.init(allocator);
    defer log.deinit();

    var smallest_key = [_]u8{'a'};
    var largest_key = [_]u8{'m'};
    {
        var manager = try Manager.create(allocator, &log, .{ .comparator_id = 42 }, {});
        defer manager.deinit();
        _ = try manager.reserveLsns(20);
        _ = try manager.reserveTableIds(3);

        const first = table(1, 1, 10, &smallest_key, &largest_key);
        const second = table(2, 11, 20, "n", "z");
        try manager.publish(.{ .added_tables = &.{ first, second } });
        smallest_key[0] = 'x';
        largest_key[0] = 'y';

        try std.testing.expectEqual(@as(usize, 2), manager.tables().len);
        try std.testing.expectEqualSlices(u8, "a", manager.tables()[0].smallest_key);
        try std.testing.expectEqualSlices(u8, "m", manager.tables()[0].largest_key);
        try std.testing.expect(manager.findTable(1) != null);
        try std.testing.expect(manager.findTable(9) == null);
        const tables_ptr = manager.tables().ptr;
        const smallest_key_ptr = manager.tables()[0].smallest_key.ptr;
        _ = try manager.nextLsn();
        _ = try manager.nextTableId();
        try std.testing.expectEqual(tables_ptr, manager.tables().ptr);
        try std.testing.expectEqual(smallest_key_ptr, manager.tables()[0].smallest_key.ptr);

        const replacement = table(3, 1, 20, "a", "z");
        try manager.publish(.{
            .added_tables = &.{replacement},
            .removed_table_ids = &.{ 1, 2 },
        });
        try std.testing.expectEqual(@as(usize, 1), manager.tables().len);
        try std.testing.expectEqual(@as(u64, 3), manager.tables()[0].table_id);
        try std.testing.expectError(error.BadTable, manager.publish(.{
            .added_tables = &.{first},
        }));
    }

    var reopened = try Manager.open(allocator, &log, .{ .comparator_id = 42 }, {});
    defer reopened.deinit();
    try std.testing.expectEqual(@as(u64, 21), reopened.lastAssignedLsn());
    try std.testing.expectEqual(@as(usize, 1), reopened.tables().len);
    const restored = reopened.tables()[0];
    try std.testing.expectEqual(@as(u64, 3), restored.table_id);
    try std.testing.expectEqual(@as(u64, 4096), restored.file_size);
    try std.testing.expectEqual(@as(u64, 8), restored.entry_count);
    try std.testing.expectEqual(@as(u64, 3), restored.keys_count);
    try std.testing.expectEqual(@as(u64, 1), restored.min_lsn);
    try std.testing.expectEqual(@as(u64, 20), restored.max_lsn);
    try std.testing.expectEqualSlices(u8, "a", restored.smallest_key);
    try std.testing.expectEqualSlices(u8, "z", restored.largest_key);
}

test "SSTable manager does not repair an incomplete initial snapshot" {
    var log = try Log.init(allocator);
    defer log.deinit();
    {
        var manager = try Manager.create(allocator, &log, .{ .comparator_id = 42 }, {});
        manager.deinit();
    }
    log.buf.shrinkRetainingCapacity(log.buf.items.len - 1);
    log.synced = log.size();
    const size_before = log.size();

    try std.testing.expectError(
        error.BadFrame,
        Manager.open(allocator, &log, .{ .comparator_id = 42 }, {}),
    );
    try std.testing.expectEqual(size_before, log.size());
}

test "SSTable manager rejects invalid edits before changing metadata" {
    var log = try Log.init(allocator);
    defer log.deinit();
    var manager = try Manager.create(allocator, &log, .{ .comparator_id = 42 }, {});
    defer manager.deinit();
    _ = try manager.reserveLsns(10);
    _ = try manager.reserveTableIds(2);
    const first = table(1, 1, 10, "a", "z");
    try manager.publish(.{ .added_tables = &.{first} });
    const size_before = log.size();

    try std.testing.expectError(error.TableNotFound, manager.publish(.{
        .removed_table_ids = &.{9},
    }));
    try std.testing.expectError(error.DuplicateTable, manager.publish(.{
        .added_tables = &.{first},
    }));
    try std.testing.expectError(error.DuplicateTable, manager.publish(.{
        .removed_table_ids = &.{ 1, 1 },
    }));
    const future = table(2, 11, 11, "a", "z");
    try std.testing.expectError(error.BadTable, manager.publish(.{
        .added_tables = &.{future},
    }));
    const reversed = table(2, 1, 10, "z", "a");
    try std.testing.expectError(error.BadTable, manager.publish(.{
        .added_tables = &.{reversed},
    }));

    try std.testing.expectEqual(size_before, log.size());
    try std.testing.expectEqual(@as(usize, 1), manager.tables().len);
}

test "SSTable manager removes an incomplete final snapshot during open" {
    var log = try Log.init(allocator);
    defer log.deinit();
    var committed_size: u64 = undefined;

    {
        var manager = try Manager.create(allocator, &log, .{ .comparator_id = 42 }, {});
        defer manager.deinit();
        _ = try manager.reserveLsns(10);
        _ = try manager.nextTableId();
        committed_size = log.size();
        const info = table(1, 1, 10, "alpha", "omega");
        try manager.publish(.{ .added_tables = &.{info} });
    }

    log.buf.shrinkRetainingCapacity(log.buf.items.len - 1);
    log.synced = log.size();
    var reopened = try Manager.open(allocator, &log, .{ .comparator_id = 42 }, {});
    defer reopened.deinit();

    try std.testing.expectEqual(committed_size, log.size());
    try std.testing.expectEqual(log.size(), log.synced);
    try std.testing.expectEqual(@as(u64, 10), reopened.lastAssignedLsn());
    try std.testing.expectEqual(@as(usize, 0), reopened.tables().len);
}

test "SSTable manager keeps the old set after an incomplete replacement" {
    var log = try Log.init(allocator);
    defer log.deinit();
    var committed_size: u64 = undefined;

    {
        var manager = try Manager.create(allocator, &log, .{ .comparator_id = 42 }, {});
        defer manager.deinit();
        _ = try manager.reserveLsns(10);
        _ = try manager.reserveTableIds(2);
        const old_table = table(1, 1, 10, "a", "z");
        try manager.publish(.{ .added_tables = &.{old_table} });
        committed_size = log.size();
        const replacement = table(2, 1, 10, "a", "z");
        try manager.publish(.{
            .added_tables = &.{replacement},
            .removed_table_ids = &.{1},
        });
    }

    log.buf.shrinkRetainingCapacity(log.buf.items.len - 1);
    log.synced = log.size();
    var reopened = try Manager.open(allocator, &log, .{ .comparator_id = 42 }, {});
    defer reopened.deinit();
    try std.testing.expectEqual(committed_size, log.size());
    try std.testing.expectEqual(@as(usize, 1), reopened.tables().len);
    try std.testing.expectEqual(@as(u64, 1), reopened.tables()[0].table_id);
}

test "SSTable manager rejects corruption before the final snapshot" {
    var log = try Log.init(allocator);
    defer log.deinit();
    var table_edit_start: usize = undefined;
    var table_edit_end: usize = undefined;

    {
        var manager = try Manager.create(allocator, &log, .{ .comparator_id = 42 }, {});
        defer manager.deinit();
        _ = try manager.reserveLsns(10);
        _ = try manager.nextTableId();
        table_edit_start = @intCast(log.size());
        const info = table(1, 1, 10, "alpha", "omega");
        try manager.publish(.{ .added_tables = &.{info} });
        table_edit_end = @intCast(log.size());
        _ = try manager.nextLsn();
    }

    log.buf.items[table_edit_end - 1] ^= 1;
    try std.testing.expect(table_edit_end > table_edit_start);
    try std.testing.expectError(
        error.BadChecksum,
        Manager.open(allocator, &log, .{ .comparator_id = 42 }, {}),
    );
    try std.testing.expectError(
        error.ComparatorMismatch,
        Manager.open(allocator, &log, .{ .comparator_id = 7 }, {}),
    );
}

test "SSTable manager fails closed on final checksum corruption" {
    var log = try Log.init(allocator);
    defer log.deinit();

    {
        var manager = try Manager.create(allocator, &log, .{ .comparator_id = 42 }, {});
        defer manager.deinit();
        _ = try manager.reserveLsns(10);
        _ = try manager.nextTableId();
        const info = table(1, 1, 10, "alpha", "omega");
        try manager.publish(.{ .added_tables = &.{info} });
    }

    const size_before = log.size();
    log.buf.items[log.buf.items.len - 1] ^= 1;
    try std.testing.expectError(
        error.BadChecksum,
        Manager.open(allocator, &log, .{ .comparator_id = 42 }, {}),
    );
    try std.testing.expectEqual(size_before, log.size());
}

test "SSTable manager authenticates frame size before tail repair" {
    var log = try Log.init(allocator);
    defer log.deinit();
    var frame_start: usize = undefined;

    {
        var manager = try Manager.create(allocator, &log, .{ .comparator_id = 42 }, {});
        defer manager.deinit();
        frame_start = @intCast(log.size());
        _ = try manager.nextLsn();
        _ = try manager.nextLsn();
    }

    const size_before = log.size();
    const frame_size_offset = 8 + @sizeOf(u16) + @sizeOf(u16);
    log.buf.items[frame_start + frame_size_offset] ^= 1;
    try std.testing.expectError(
        error.BadHeaderChecksum,
        Manager.open(allocator, &log, .{ .comparator_id = 42 }, {}),
    );
    try std.testing.expectEqual(size_before, log.size());
}

const FailingSyncLog = struct {
    const Self = @This();
    const Inner = Log;

    pub const Error = Inner.Error || error{SyncFailed};
    pub const Offset = Inner.Offset;

    inner: Inner,
    fail_sync: bool = false,

    fn init() Error!Self {
        return .{ .inner = try Inner.init(allocator) };
    }

    fn deinit(self: *Self) void {
        self.inner.deinit();
    }

    pub fn append(self: *Self, bytes: []const u8) Error!void {
        return self.inner.append(bytes);
    }

    pub fn sync(self: *Self) Error!void {
        if (self.fail_sync) {
            return error.SyncFailed;
        }
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

    pub fn readAt(self: *const Self, offset: Offset, dst: []u8) Error!void {
        return self.inner.readAt(offset, dst);
    }
};

test "SSTable manager requires recovery after an uncertain metadata sync" {
    const FailingManager = sstable.SstableManager(
        Format,
        FailingSyncLog,
        compareBytes,
        void,
    );
    var log = try FailingSyncLog.init();
    defer log.deinit();
    var manager = try FailingManager.create(
        allocator,
        &log,
        .{ .comparator_id = 42 },
        {},
    );
    log.fail_sync = true;
    try std.testing.expectError(error.SyncFailed, manager.nextLsn());
    try std.testing.expect(manager.isRecoveryRequired());
    try std.testing.expectError(error.RecoveryRequired, manager.nextLsn());
    manager.deinit();

    log.fail_sync = false;
    var reopened = try FailingManager.open(
        allocator,
        &log,
        .{ .comparator_id = 42 },
        {},
    );
    defer reopened.deinit();
    try std.testing.expectEqual(@as(u64, 1), reopened.lastAssignedLsn());
    try std.testing.expectEqual(log.inner.size(), log.inner.synced);
}

test "SSTable manager recovers a complete replacement after failed sync" {
    const FailingManager = sstable.SstableManager(
        Format,
        FailingSyncLog,
        compareBytes,
        void,
    );
    var log = try FailingSyncLog.init();
    defer log.deinit();
    var manager = try FailingManager.create(
        allocator,
        &log,
        .{ .comparator_id = 42 },
        {},
    );
    _ = try manager.reserveLsns(10);
    _ = try manager.reserveTableIds(2);
    const old_table: FailingManager.TableInfo = .{
        .table_id = 1,
        .file_size = 100,
        .entry_count = 2,
        .keys_count = 1,
        .min_lsn = 1,
        .max_lsn = 5,
        .smallest_key = "a",
        .largest_key = "z",
    };
    try manager.publish(.{ .added_tables = &.{old_table} });

    const replacement: FailingManager.TableInfo = .{
        .table_id = 2,
        .file_size = 120,
        .entry_count = 3,
        .keys_count = 2,
        .min_lsn = 1,
        .max_lsn = 10,
        .smallest_key = "a",
        .largest_key = "z",
    };
    log.fail_sync = true;
    try std.testing.expectError(error.SyncFailed, manager.publish(.{
        .added_tables = &.{replacement},
        .removed_table_ids = &.{1},
    }));
    try std.testing.expectEqual(@as(u64, 1), manager.tables()[0].table_id);
    manager.deinit();

    log.fail_sync = false;
    var reopened = try FailingManager.open(
        allocator,
        &log,
        .{ .comparator_id = 42 },
        {},
    );
    defer reopened.deinit();
    try std.testing.expectEqual(@as(usize, 1), reopened.tables().len);
    try std.testing.expectEqual(@as(u64, 2), reopened.tables()[0].table_id);
    try std.testing.expectEqual(log.inner.size(), log.inner.synced);
}

test "SSTable manager publishes statistics from a finished versioned table" {
    const Writer = sstable.Writer(Format, Log, compareBytes, void);
    const settings: sstable.Settings = .{
        .max_entries_per_coded_block = 2,
        .max_coded_block_bytes = 128,
        .data_page_bytes = 256,
        .index_page_bytes = 512,
        .max_key_bytes = 16,
        .max_value_bytes = 32,
    };
    var table_log = try Log.init(allocator);
    defer table_log.deinit();
    var writer = try Writer.init(allocator, &table_log, .{
        .entry_count = 3,
        .keys_count = 2,
        .comparator_id = 42,
        .settings = settings,
    }, {});
    defer writer.deinit();
    try writer.addWithMetadata("alpha", "new", .{ .flags = .value, .lsn = 3 });
    try writer.addWithMetadata("alpha", "old", .{ .flags = .value, .lsn = 1 });
    try writer.addWithMetadata("omega", "value", .{ .flags = .value, .lsn = 2 });
    try writer.finish();

    var metadata_log = try Log.init(allocator);
    defer metadata_log.deinit();
    var manager = try Manager.create(allocator, &metadata_log, .{ .comparator_id = 42 }, {});
    defer manager.deinit();
    _ = try manager.reserveLsns(3);
    const table_id = try manager.nextTableId();
    const info: Manager.TableInfo = .{
        .table_id = table_id,
        .file_size = table_log.size(),
        .entry_count = @intCast(writer.entry_count),
        .keys_count = @intCast(writer.keys_count),
        .min_lsn = writer.min_lsn,
        .max_lsn = writer.max_lsn,
        .smallest_key = "alpha",
        .largest_key = "omega",
    };
    try manager.publish(.{ .added_tables = &.{info} });

    const stored = manager.tables()[0];
    try std.testing.expectEqual(table_log.size(), stored.file_size);
    try std.testing.expectEqual(@as(u64, 3), stored.entry_count);
    try std.testing.expectEqual(@as(u64, 2), stored.keys_count);
    try std.testing.expectEqual(@as(u64, 1), stored.min_lsn);
    try std.testing.expectEqual(@as(u64, 3), stored.max_lsn);
}

test "SSTable manager supports ordinary tables and alternate wire types" {
    const OrdinaryFormat = sstable.SstableFormatWithLsn(u32, u16, u16, u16, .big);
    const OrdinaryLog = fullaz.device.MemoryLog(u32);
    const OrdinaryManager = sstable.SstableManager(
        OrdinaryFormat,
        OrdinaryLog,
        compareBytes,
        void,
    );
    var log = try OrdinaryLog.init(allocator);
    defer log.deinit();

    {
        var manager = try OrdinaryManager.create(
            allocator,
            &log,
            .{ .comparator_id = 9 },
            {},
        );
        defer manager.deinit();
        _ = try manager.reserveLsns(7);
        const table_id = try manager.nextTableId();
        const info: OrdinaryManager.TableInfo = .{
            .table_id = table_id,
            .file_size = 100,
            .entry_count = 2,
            .keys_count = 2,
            .min_lsn = 3,
            .max_lsn = 7,
            .smallest_key = "a",
            .largest_key = "z",
        };
        try manager.publish(.{ .added_tables = &.{info} });
    }

    var reopened = try OrdinaryManager.open(
        allocator,
        &log,
        .{ .comparator_id = 9 },
        {},
    );
    defer reopened.deinit();
    try std.testing.expectEqual(@as(u16, 7), reopened.lastAssignedLsn());
    try std.testing.expectEqual(@as(u64, 1), reopened.lastAssignedTableId());
    try std.testing.expectEqual(@as(usize, 1), reopened.tables().len);
    try std.testing.expectEqualSlices(u8, "a", reopened.tables()[0].smallest_key);
}
