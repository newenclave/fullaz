const std = @import("std");
const fullaz = @import("fullaz");
const models = fullaz.lsm.models;
const value = fullaz.lsm.value;
const merge_cursor = fullaz.lsm.merge_cursor;

const ValueCodec = value.Value(u64, .native);
const Entry = models.entry.Entry(u64);

const FakeCursor = struct {
    const Self = @This();
    pub const Error = error{};
    pub const LsnType = u64;

    entries: []const Entry,
    idx: usize = 0,

    pub fn peek(self: *const Self) Error!?Entry {
        if (self.idx >= self.entries.len) {
            return null;
        }
        return self.entries[self.idx];
    }

    pub fn advance(self: *Self) Error!void {
        self.idx += 1;
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }
};

const M = merge_cursor.MergeCursor(FakeCursor);

test "LSM MergeCursor satisfies the KvCursor contract" {
    comptime models.interfaces.assertKvCursor(M);
}

test "LSM MergeCursor: newest-wins dedup across three sources" {
    var buf_a1: [16]u8 = undefined;
    var buf_c3: [16]u8 = undefined;
    var buf_aX: [16]u8 = undefined;
    var buf_b2: [16]u8 = undefined;
    var buf_aY: [16]u8 = undefined;
    var buf_bZ: [16]u8 = undefined;
    var buf_d4: [16]u8 = undefined;

    // cursor0 is written newest (highest lsn), cursor2 oldest -- recency is
    // now decided by these lsn values, not by cursor array position.
    const cursor0 = FakeCursor{ .entries = &.{
        .{ .key = "a", .value = ValueCodec.encodePut(&buf_a1, "1", 100), .lsn = 100 },
        .{ .key = "c", .value = ValueCodec.encodePut(&buf_c3, "3", 101), .lsn = 101 },
    } };
    const cursor1 = FakeCursor{ .entries = &.{
        .{ .key = "a", .value = ValueCodec.encodePut(&buf_aX, "X", 50), .lsn = 50 },
        .{ .key = "b", .value = ValueCodec.encodePut(&buf_b2, "2", 51), .lsn = 51 },
    } };
    const cursor2 = FakeCursor{ .entries = &.{
        .{ .key = "a", .value = ValueCodec.encodePut(&buf_aY, "Y", 10), .lsn = 10 },
        .{ .key = "b", .value = ValueCodec.encodePut(&buf_bZ, "Z", 11), .lsn = 11 },
        .{ .key = "d", .value = ValueCodec.encodePut(&buf_d4, "4", 12), .lsn = 12 },
    } };

    var cursors = [_]FakeCursor{ cursor0, cursor1, cursor2 };
    var merged = try M.init(&cursors, false);
    defer merged.deinit();

    const expect_keys = [_][]const u8{ "a", "b", "c", "d" };
    const expect_vals = [_][]const u8{ "1", "2", "3", "4" };
    var i: usize = 0;
    while (try merged.peek()) |e| : (try merged.advance()) {
        try std.testing.expectEqualSlices(u8, expect_keys[i], e.key);
        try std.testing.expectEqualSlices(u8, expect_vals[i], ValueCodec.payloadOf(e.value));
        i += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), i);
}

test "LSM MergeCursor: tie-break is decided by lsn, not cursor array position" {
    var buf0: [16]u8 = undefined;
    var buf1: [16]u8 = undefined;
    var buf2: [16]u8 = undefined;

    const oldest = FakeCursor{ .entries = &.{
        .{ .key = "a", .value = ValueCodec.encodePut(&buf0, "old", 5), .lsn = 5 },
    } };
    const mid = FakeCursor{ .entries = &.{
        .{ .key = "a", .value = ValueCodec.encodePut(&buf1, "mid", 10), .lsn = 10 },
    } };
    const newest = FakeCursor{ .entries = &.{
        .{ .key = "a", .value = ValueCodec.encodePut(&buf2, "new", 20), .lsn = 20 },
    } };

    const arrangements = [_][3]FakeCursor{
        .{ oldest, mid, newest },
        .{ newest, oldest, mid },
        .{ mid, newest, oldest },
    };

    for (arrangements) |arrangement| {
        var cursors = arrangement;
        var merged = try M.init(&cursors, false);
        defer merged.deinit();

        const e = (try merged.peek()).?;
        try std.testing.expectEqualSlices(u8, "new", ValueCodec.payloadOf(e.value));
        try std.testing.expectEqual(@as(u64, 20), e.lsn);
    }
}

test "LSM MergeCursor: drop_tombstones consumes the shadowed key entirely" {
    var buf_a1: [16]u8 = undefined;
    var buf_b2: [16]u8 = undefined;
    var buf_c3: [16]u8 = undefined;
    var buf_btomb: [16]u8 = undefined;

    const newer = FakeCursor{ .entries = &.{
        .{ .key = "b", .value = ValueCodec.encodeTombstone(&buf_btomb, 100), .lsn = 100 },
    } };
    const older = FakeCursor{ .entries = &.{
        .{ .key = "a", .value = ValueCodec.encodePut(&buf_a1, "1", 10), .lsn = 10 },
        .{ .key = "b", .value = ValueCodec.encodePut(&buf_b2, "2", 11), .lsn = 11 },
        .{ .key = "c", .value = ValueCodec.encodePut(&buf_c3, "3", 12), .lsn = 12 },
    } };

    var cursors = [_]FakeCursor{ newer, older };
    var merged = try M.init(&cursors, true);
    defer merged.deinit();

    const expect_keys = [_][]const u8{ "a", "c" };
    var i: usize = 0;
    while (try merged.peek()) |e| : (try merged.advance()) {
        try std.testing.expectEqualSlices(u8, expect_keys[i], e.key);
        i += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), i);
}

test "LSM MergeCursor: without drop_tombstones the tombstone is carried through" {
    var buf_a1: [16]u8 = undefined;
    var buf_b2: [16]u8 = undefined;
    var buf_c3: [16]u8 = undefined;
    var buf_btomb: [16]u8 = undefined;

    const newer = FakeCursor{ .entries = &.{
        .{ .key = "b", .value = ValueCodec.encodeTombstone(&buf_btomb, 100), .lsn = 100 },
    } };
    const older = FakeCursor{ .entries = &.{
        .{ .key = "a", .value = ValueCodec.encodePut(&buf_a1, "1", 10), .lsn = 10 },
        .{ .key = "b", .value = ValueCodec.encodePut(&buf_b2, "2", 11), .lsn = 11 },
        .{ .key = "c", .value = ValueCodec.encodePut(&buf_c3, "3", 12), .lsn = 12 },
    } };

    var cursors = [_]FakeCursor{ newer, older };
    var merged = try M.init(&cursors, false);
    defer merged.deinit();

    const expect_keys = [_][]const u8{ "a", "b", "c" };
    var i: usize = 0;
    while (try merged.peek()) |e| : (try merged.advance()) {
        try std.testing.expectEqualSlices(u8, expect_keys[i], e.key);
        if (i == 1) {
            try std.testing.expect(value.isTombstone(e.value));
        }
        i += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), i);
}

test "LSM MergeCursor: zero cursors" {
    var cursors: [0]FakeCursor = .{};
    var merged = try M.init(&cursors, false);
    defer merged.deinit();

    try std.testing.expectEqual(@as(?Entry, null), try merged.peek());
    try merged.advance();
}

test "LSM MergeCursor: all-exhausted cursors" {
    const c0 = FakeCursor{ .entries = &.{} };
    const c1 = FakeCursor{ .entries = &.{} };
    var cursors = [_]FakeCursor{ c0, c1 };
    var merged = try M.init(&cursors, false);
    defer merged.deinit();

    try std.testing.expectEqual(@as(?Entry, null), try merged.peek());
}

test "LSM MergeCursor: an all-tombstone run does not overflow the stack" {
    const allocator = std.testing.allocator;
    const n = 200_000;
    const buf_len = comptime ValueCodec.encodedLen(0);

    const entries = try allocator.alloc(Entry, n);
    defer allocator.free(entries);
    const bufs = try allocator.alloc([buf_len]u8, n);
    defer allocator.free(bufs);
    const keys = try allocator.alloc([16]u8, n);
    defer allocator.free(keys);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = try std.fmt.bufPrint(&keys[i], "key-{d:0>6}", .{i});
        entries[i] = .{ .key = key, .value = ValueCodec.encodeTombstone(&bufs[i], @intCast(i)), .lsn = @intCast(i) };
    }

    const cursor = FakeCursor{ .entries = entries };
    var cursors = [_]FakeCursor{cursor};
    var merged = try M.init(&cursors, true);
    defer merged.deinit();

    try std.testing.expectEqual(@as(?Entry, null), try merged.peek());
}
