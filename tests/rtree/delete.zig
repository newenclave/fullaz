const std = @import("std");
const fullaz = @import("fullaz");
const rtree = fullaz.rtree;

const testing = std.testing;

const Model = rtree.models.Memory(i64, 2, u64, 4);
const Key = Model.KeyType;

fn box(x0: i64, y0: i64, x1: i64, y1: i64) Key {
    return Key.initWith(.{ x0, y0 }, .{ x1, y1 });
}

const Collector = struct {
    seen: [256]bool = [_]bool{false} ** 256,
    count: usize = 0,
    fn cb(self: *Collector, _: Key, value: u64) anyerror!void {
        self.seen[value] = true;
        self.count += 1;
    }
};

fn matchValue(target: *const u64, _: Key, value: u64) bool {
    return value == target.*;
}

fn runDeleteTest(comptime Tree: type) !void {
    var m = try Model.init(testing.allocator);
    defer m.deinit();
    var t = Tree.init(&m);

    const N = 50;
    var boxes: [N]Key = undefined;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const x: i64 = @intCast((i * 7) % 20);
        const y: i64 = @intCast((i * 11) % 20);
        boxes[i] = box(x, y, x + 2, y + 2);
        try t.insert(boxes[i], @intCast(i));
    }

    // Remove all even-valued entries (predicate disambiguates coincident boxes).
    i = 0;
    while (i < N) : (i += 2) {
        var target: u64 = @intCast(i);
        try testing.expect(try t.remove(boxes[i], &target, matchValue));
    }

    // Removing something absent returns false.
    {
        var target: u64 = 12345;
        try testing.expect(!(try t.remove(box(0, 0, 1, 1), &target, matchValue)));
    }

    // Full query: exactly the odd values remain, each once.
    {
        var got = Collector{};
        try t.search(box(-5, -5, 100, 100), &got, Collector.cb);
        try testing.expectEqual(@as(usize, N / 2), got.count);
        i = 0;
        while (i < N) : (i += 1) {
            try testing.expectEqual((i % 2) == 1, got.seen[i]);
        }
    }

    // Window queries still match a brute-force scan over the remaining set.
    const queries = [_]Key{ box(0, 0, 6, 6), box(8, 8, 16, 16), box(0, 0, 25, 25) };
    for (queries) |q| {
        var got = Collector{};
        try t.search(q, &got, Collector.cb);
        i = 0;
        while (i < N) : (i += 1) {
            const remaining = (i % 2) == 1;
            try testing.expectEqual(remaining and boxes[i].overlaps(&q), got.seen[i]);
        }
    }

    // Remove the rest -> empty tree.
    i = 1;
    while (i < N) : (i += 2) {
        var target: u64 = @intCast(i);
        try testing.expect(try t.remove(boxes[i], &target, matchValue));
    }
    {
        var got = Collector{};
        try t.search(box(-5, -5, 100, 100), &got, Collector.cb);
        try testing.expectEqual(@as(usize, 0), got.count);
    }
    try testing.expectEqual(@as(usize, 0), try t.height());
}

test "RTree delete: condense keeps the remaining set exact" {
    try runDeleteTest(rtree.RTree(Model));
}

test "RStarTree delete: condense keeps the remaining set exact" {
    try runDeleteTest(rtree.RStarTree(Model));
}
