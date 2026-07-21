const std = @import("std");
const fullaz = @import("fullaz");
const algorithm = fullaz.core.algorithm;
const models = fullaz.lsm.models;
const value = fullaz.lsm.value;
const SortedVector = fullaz.lsm.memtable.SortedVector;
const SortedVectorImpl = fullaz.lsm.memtable.SortedVectorImpl;

const ValueCodec = value.Value(u64, .native);
const Entry = models.entry.Entry(u64);

test "LSM memtable: SortedVector satisfies the memtable contract" {
    comptime models.interfaces.assertMemtable(SortedVector);
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

// put()/get() never look inside value -- they are pure opaque-byte storage,
// so the tests above are free to use plain strings. iterator()/seek() do
// decode an lsn out of value (via peek()), so from here on every stored
// value must be a real Value(u64, .native)-encoded blob.

test "LSM memtable: iterator yields entries in ascending key order" {
    var mt = try SortedVector.init(std.testing.allocator);
    defer mt.deinit();

    var buf: [32]u8 = undefined;
    try mt.put("c", ValueCodec.encodePut(&buf, "3", 0));
    try mt.put("a", ValueCodec.encodePut(&buf, "1", 0));
    try mt.put("b", ValueCodec.encodePut(&buf, "2", 0));

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

    var buf: [32]u8 = undefined;
    try mt.put("a", ValueCodec.encodePut(&buf, "1", 0));
    try mt.put("c", ValueCodec.encodePut(&buf, "3", 0));
    try mt.put("e", ValueCodec.encodePut(&buf, "5", 0));

    var it = try mt.seek("b");
    defer it.deinit();
    try std.testing.expectEqualSlices(u8, "c", (try it.peek()).?.key);

    var it2 = try mt.seek("c");
    defer it2.deinit();
    try std.testing.expectEqualSlices(u8, "c", (try it2.peek()).?.key);

    var it3 = try mt.seek("z");
    defer it3.deinit();
    try std.testing.expectEqual(@as(?Entry, null), try it3.peek());
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
    const RevVector = SortedVectorImpl(revCmp, Ctx, ValueCodec);

    var mt = try RevVector.initWithContext(std.testing.allocator, .{ .reverse = true });
    defer mt.deinit();

    var buf: [32]u8 = undefined;
    try mt.put("a", ValueCodec.encodePut(&buf, "1", 0));
    try mt.put("c", ValueCodec.encodePut(&buf, "3", 0));
    try mt.put("b", ValueCodec.encodePut(&buf, "2", 0));

    var it = try mt.iterator();
    defer it.deinit();
    const want = [_][]const u8{ "c", "b", "a" };
    var i: usize = 0;
    while (try it.peek()) |e| : (try it.advance()) {
        try std.testing.expectEqualSlices(u8, want[i], e.key);
        i += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), i);

    try std.testing.expectEqualSlices(u8, "2", ValueCodec.payloadOf((try mt.get("b")).?));
}

test "LSM memtable: pointer context lets the comparator mutate shared state" {
    const SortStat = struct { comparisons: usize = 0 };
    const statCmp = struct {
        fn cmp(ctx: *SortStat, a: []const u8, b: []const u8) algorithm.Order {
            ctx.comparisons += 1;
            return algorithm.cmpSlices(u8, a, b, algorithm.CmpNum(u8).asc, {}) catch unreachable;
        }
    }.cmp;
    const StatVector = SortedVectorImpl(statCmp, *SortStat, ValueCodec);

    var stat = SortStat{};
    var mt = try StatVector.initWithContext(std.testing.allocator, &stat);
    defer mt.deinit();

    try mt.put("b", "2");
    try mt.put("a", "1");
    try mt.put("c", "3");
    _ = try mt.get("a"); // get takes *const Self, yet still mutates stat via the pointer

    try std.testing.expect(stat.comparisons > 0);
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
