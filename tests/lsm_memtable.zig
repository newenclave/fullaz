const std = @import("std");
const fullaz = @import("fullaz");
const algorithm = fullaz.core.algorithm;
const strategy = fullaz.lsm.strategy;
const SortedVector = fullaz.lsm.memtable.SortedVector;
const SortedVectorImpl = fullaz.lsm.memtable.SortedVectorImpl;

test "LSM memtable: SortedVector satisfies the memtable contract" {
    comptime strategy.assertMemtable(SortedVector);
}

test "LSM memtable: put then get, upsert overwrites" {
    var mt = try SortedVector.init(std.testing.allocator);
    defer mt.deinit();

    try mt.put("banana", "yellow");
    try mt.put("apple", "red");

    try std.testing.expectEqualSlices(u8, "yellow", (try mt.get("banana")).?);
    try std.testing.expectEqualSlices(u8, "red", (try mt.get("apple")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try mt.get("cherry"));

    try mt.put("apple", "green");
    try std.testing.expectEqualSlices(u8, "green", (try mt.get("apple")).?);
    try std.testing.expectEqual(@as(usize, 2), mt.count());
}

test "LSM memtable: count and byteSize track entries" {
    var mt = try SortedVector.init(std.testing.allocator);
    defer mt.deinit();

    try std.testing.expectEqual(@as(usize, 0), mt.count());
    try mt.put("k1", "vv");
    try mt.put("k2", "vvvv");
    try std.testing.expectEqual(@as(usize, 2), mt.count());
    try std.testing.expectEqual(@as(usize, 10), mt.byteSize());

    try mt.put("k1", "v"); // overwrite: bytes 10 - 2 + 1 = 9
    try std.testing.expectEqual(@as(usize, 9), mt.byteSize());
    try std.testing.expectEqual(@as(usize, 2), mt.count());
}

test "LSM memtable: iterator yields entries in ascending key order" {
    var mt = try SortedVector.init(std.testing.allocator);
    defer mt.deinit();

    try mt.put("c", "3");
    try mt.put("a", "1");
    try mt.put("b", "2");

    var it = try mt.iterator();
    defer it.deinit();
    const expect_keys = [_][]const u8{ "a", "b", "c" };
    var i: usize = 0;
    while (try it.peek()) |e| : (try it.advance()) {
        try std.testing.expectEqualSlices(u8, expect_keys[i], e.key);
        i += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), i);
}

test "LSM memtable: seek positions at first key >= target" {
    var mt = try SortedVector.init(std.testing.allocator);
    defer mt.deinit();

    try mt.put("a", "1");
    try mt.put("c", "3");
    try mt.put("e", "5");

    var it = try mt.seek("b");
    defer it.deinit();
    try std.testing.expectEqualSlices(u8, "c", (try it.peek()).?.key);

    var it2 = try mt.seek("c");
    defer it2.deinit();
    try std.testing.expectEqualSlices(u8, "c", (try it2.peek()).?.key);

    var it3 = try mt.seek("z");
    defer it3.deinit();
    try std.testing.expectEqual(@as(?strategy.Entry, null), try it3.peek());
}

test "LSM memtable: custom comparator context flows into ordering" {
    const Ctx = struct { reverse: bool };
    const revCmp = struct {
        fn cmp(ctx: Ctx, a: []const u8, b: []const u8) algorithm.Order {
            const o = algorithm.cmpSlices(u8, a, b, algorithm.CmpNum(u8).asc, {}) catch unreachable;
            if (!ctx.reverse) {
                return o;
            }
            return switch (o) {
                .lt => .gt,
                .gt => .lt,
                else => o,
            };
        }
    }.cmp;
    const RevVector = SortedVectorImpl(revCmp, Ctx);

    var mt = try RevVector.initWithContext(std.testing.allocator, .{ .reverse = true });
    defer mt.deinit();

    try mt.put("a", "1");
    try mt.put("c", "3");
    try mt.put("b", "2");

    var it = try mt.iterator();
    defer it.deinit();
    const want = [_][]const u8{ "c", "b", "a" };
    var i: usize = 0;
    while (try it.peek()) |e| : (try it.advance()) {
        try std.testing.expectEqualSlices(u8, want[i], e.key);
        i += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), i);

    try std.testing.expectEqualSlices(u8, "2", (try mt.get("b")).?);
}

test "LSM memtable: reset clears entries and stays usable" {
    var mt = try SortedVector.init(std.testing.allocator);
    defer mt.deinit();

    try mt.put("a", "1");
    try mt.put("b", "2");
    try mt.reset();

    try std.testing.expectEqual(@as(usize, 0), mt.count());
    try std.testing.expectEqual(@as(usize, 0), mt.byteSize());
    try std.testing.expectEqual(@as(?[]const u8, null), try mt.get("a"));

    try mt.put("z", "9");
    try std.testing.expectEqualSlices(u8, "9", (try mt.get("z")).?);
}
