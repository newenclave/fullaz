const std = @import("std");
const fullaz = @import("fullaz");
const models = fullaz.lsm.models;
const value = fullaz.lsm.value;
const merge_cursor = fullaz.lsm.merge_cursor;

const FakeCursor = struct {
    const Self = @This();
    pub const Error = error{};

    entries: []const models.entry.Entry,
    idx: usize = 0,

    pub fn peek(self: *const Self) Error!?models.entry.Entry {
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
    var buf_a1: [2]u8 = undefined;
    var buf_c3: [2]u8 = undefined;
    var buf_aX: [2]u8 = undefined;
    var buf_b2: [2]u8 = undefined;
    var buf_aY: [2]u8 = undefined;
    var buf_bZ: [2]u8 = undefined;
    var buf_d4: [2]u8 = undefined;

    const cursor0 = FakeCursor{ .entries = &.{
        .{ .key = "a", .value = value.encodePut(&buf_a1, "1") },
        .{ .key = "c", .value = value.encodePut(&buf_c3, "3") },
    } };
    const cursor1 = FakeCursor{ .entries = &.{
        .{ .key = "a", .value = value.encodePut(&buf_aX, "X") },
        .{ .key = "b", .value = value.encodePut(&buf_b2, "2") },
    } };
    const cursor2 = FakeCursor{ .entries = &.{
        .{ .key = "a", .value = value.encodePut(&buf_aY, "Y") },
        .{ .key = "b", .value = value.encodePut(&buf_bZ, "Z") },
        .{ .key = "d", .value = value.encodePut(&buf_d4, "4") },
    } };

    var cursors = [_]FakeCursor{ cursor0, cursor1, cursor2 };
    var merged = try M.init(&cursors, false);
    defer merged.deinit();

    const expect_keys = [_][]const u8{ "a", "b", "c", "d" };
    const expect_vals = [_][]const u8{ "1", "2", "3", "4" };
    var i: usize = 0;
    while (try merged.peek()) |e| : (try merged.advance()) {
        try std.testing.expectEqualSlices(u8, expect_keys[i], e.key);
        try std.testing.expectEqualSlices(u8, expect_vals[i], value.payloadOf(e.value));
        i += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), i);
}

test "LSM MergeCursor: drop_tombstones consumes the shadowed key entirely" {
    var buf_a1: [2]u8 = undefined;
    var buf_b2: [2]u8 = undefined;
    var buf_c3: [2]u8 = undefined;
    var buf_btomb: [1]u8 = undefined;

    const newer = FakeCursor{ .entries = &.{
        .{ .key = "b", .value = value.encodeTombstone(&buf_btomb) },
    } };
    const older = FakeCursor{ .entries = &.{
        .{ .key = "a", .value = value.encodePut(&buf_a1, "1") },
        .{ .key = "b", .value = value.encodePut(&buf_b2, "2") },
        .{ .key = "c", .value = value.encodePut(&buf_c3, "3") },
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
    var buf_a1: [2]u8 = undefined;
    var buf_b2: [2]u8 = undefined;
    var buf_c3: [2]u8 = undefined;
    var buf_btomb: [1]u8 = undefined;

    const newer = FakeCursor{ .entries = &.{
        .{ .key = "b", .value = value.encodeTombstone(&buf_btomb) },
    } };
    const older = FakeCursor{ .entries = &.{
        .{ .key = "a", .value = value.encodePut(&buf_a1, "1") },
        .{ .key = "b", .value = value.encodePut(&buf_b2, "2") },
        .{ .key = "c", .value = value.encodePut(&buf_c3, "3") },
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

    try std.testing.expectEqual(@as(?models.entry.Entry, null), try merged.peek());
    try merged.advance();
}

test "LSM MergeCursor: all-exhausted cursors" {
    const c0 = FakeCursor{ .entries = &.{} };
    const c1 = FakeCursor{ .entries = &.{} };
    var cursors = [_]FakeCursor{ c0, c1 };
    var merged = try M.init(&cursors, false);
    defer merged.deinit();

    try std.testing.expectEqual(@as(?models.entry.Entry, null), try merged.peek());
}

test "LSM MergeCursor: an all-tombstone run does not overflow the stack" {
    const allocator = std.testing.allocator;
    const n = 200_000;

    const entries = try allocator.alloc(models.entry.Entry, n);
    defer allocator.free(entries);
    const bufs = try allocator.alloc([1]u8, n);
    defer allocator.free(bufs);
    const keys = try allocator.alloc([16]u8, n);
    defer allocator.free(keys);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = try std.fmt.bufPrint(&keys[i], "key-{d:0>6}", .{i});
        entries[i] = .{ .key = key, .value = value.encodeTombstone(&bufs[i]) };
    }

    const cursor = FakeCursor{ .entries = entries };
    var cursors = [_]FakeCursor{cursor};
    var merged = try M.init(&cursors, true);
    defer merged.deinit();

    try std.testing.expectEqual(@as(?models.entry.Entry, null), try merged.peek());
}
