const std = @import("std");
const fullaz = @import("fullaz");
const rtree = fullaz.rtree;
const strategy = rtree.strategy;

const testing = std.testing;

const BB = rtree.BoundingBox(i64, 2);
const Linear = strategy.LinearStrategy(BB);

const Model = rtree.models.Memory(i64, 2, u64, 4); // max_entries = 4
const Key = Model.KeyType;
const LinearTree = rtree.RLinearTree(Model);

fn box(x0: i64, y0: i64, x1: i64, y1: i64) BB {
    return BB.initWith(.{ x0, y0 }, .{ x1, y1 });
}

const Collector = struct {
    seen: [128]bool = [_]bool{false} ** 128,
    count: usize = 0,
    fn cb(self: *Collector, _: Key, value: u64) anyerror!void {
        self.seen[value] = true;
        self.count += 1;
    }
};

test "rtree strategy contract: Linear satisfies assertStrategy" {
    comptime strategy.assertStrategy(Linear, BB);
    try testing.expect(!Linear.wants_reinsert);
}

test "Linear chooseSubtree: least enlargement (same as quadratic Guttman)" {
    const children = [_]BB{ box(0, 0, 2, 2), box(10, 10, 12, 12) };
    try testing.expectEqual(@as(usize, 0), Linear.chooseSubtree(&children, box(1, 1, 2, 2), true));
    try testing.expectEqual(@as(usize, 1), Linear.chooseSubtree(&children, box(11, 11, 13, 13), true));
}

test "Linear splitEntries: separates two well-separated clusters" {
    const mbrs = [_]BB{
        box(0, 0, 1, 1),     box(0, 0, 1, 1), // left cluster: idx 0,1
        box(30, 0, 31, 1), box(30, 0, 31, 1), box(30, 0, 31, 1), // right cluster: idx 2,3,4
    };
    var assign = [_]u8{9} ** 5;
    Linear.splitEntries(&mbrs, 2, &assign);

    try testing.expectEqual(assign[0], assign[1]);
    try testing.expectEqual(assign[2], assign[3]);
    try testing.expectEqual(assign[3], assign[4]);
    try testing.expect(assign[0] != assign[2]);
}

test "Linear splitEntries: valid partition respects min_fill" {
    const mbrs = [_]BB{
        box(0, 0, 1, 1), box(2, 2, 3, 3), box(4, 4, 5, 5), box(6, 6, 7, 7), box(8, 8, 9, 9),
    };
    var assign = [_]u8{9} ** 5;
    Linear.splitEntries(&mbrs, 2, &assign);

    var c0: usize = 0;
    for (assign) |a| {
        try testing.expect(a == 0 or a == 1);
        if (a == 0) c0 += 1;
    }
    try testing.expect(c0 >= 2 and (5 - c0) >= 2);
}

test "Linear splitEntries: identical boxes still respect min_fill" {
    const mbrs = [_]BB{
        box(0, 0, 1, 1), box(0, 0, 1, 1), box(0, 0, 1, 1), box(0, 0, 1, 1), box(0, 0, 1, 1),
    };
    var assign = [_]u8{9} ** 5;
    Linear.splitEntries(&mbrs, 2, &assign);

    var c0: usize = 0;
    var c1: usize = 0;
    for (assign) |a| switch (a) {
        0 => c0 += 1,
        1 => c1 += 1,
        else => unreachable,
    };
    try testing.expectEqual(@as(usize, 5), c0 + c1);
    try testing.expect(c0 >= 2);
    try testing.expect(c1 >= 2);
}

test "RLinearTree: single insert is findable, misses elsewhere" {
    var m = try Model.init(testing.allocator);
    defer m.deinit();
    var t = LinearTree.init(&m);

    try t.insert(box(2, 2, 4, 4), 7);

    var hit = Collector{};
    try t.search(box(3, 3, 3, 3), &hit, Collector.cb);
    try testing.expect(hit.seen[7]);

    var miss = Collector{};
    try t.search(box(50, 50, 60, 60), &miss, Collector.cb);
    try testing.expectEqual(@as(usize, 0), miss.count);
}

test "RLinearTree: window query matches brute force after many inserts + splits" {
    var m = try Model.init(testing.allocator);
    defer m.deinit();
    var t = LinearTree.init(&m);

    const N = 60;
    var boxes: [N]Key = undefined;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const x: i64 = @intCast((i * 7) % 25);
        const y: i64 = @intCast((i * 11) % 25);
        boxes[i] = box(x, y, x + 3, y + 3);
        try t.insert(boxes[i], @intCast(i));
    }

    // N=60 with M=4 must have split and grown past a single leaf.
    try testing.expect((try t.height()) >= 2);

    const queries = [_]Key{
        box(0, 0, 5, 5),
        box(10, 10, 20, 20),
        box(3, 3, 4, 4),
        box(0, 0, 30, 30),
        box(24, 24, 28, 28),
    };
    for (queries) |q| {
        var got = Collector{};
        try t.search(q, &got, Collector.cb);
        i = 0;
        while (i < N) : (i += 1) {
            try testing.expectEqual(boxes[i].overlaps(&q), got.seen[i]);
        }
    }
}
