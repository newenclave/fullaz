const std = @import("std");
const fullaz = @import("fullaz");
const rtree = fullaz.rtree;

const testing = std.testing;

const BB = rtree.BoundingBox(i64, 2);
const RStar = rtree.RStarStrategy(BB);

const Model = rtree.models.Memory(i64, 2, u64, 4);
const Key = Model.KeyType;
const RStarTree = rtree.RStarTree(Model);

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

test "rtree strategy contract: RStar satisfies assertStrategy (incl. reinsertOrder)" {
    comptime rtree.strategy.assertStrategy(RStar, BB);
    try testing.expect(RStar.wants_reinsert);
}

test "RStar chooseSubtree: at leaf level prefers least overlap growth" {
    // Two children; the entry could go in either by area, but child 0 already
    // overlaps child 1, so growing child 1 to include it adds less overlap.
    const children = [_]BB{ box(0, 0, 4, 4), box(3, 3, 7, 7) };
    // an entry to the far side of child 1 -> putting it in child 1 keeps overlap low
    const idx = RStar.chooseSubtree(&children, box(6, 6, 8, 8), true);
    try testing.expectEqual(@as(usize, 1), idx);
}

test "RStar splitEntries: valid partition, respects min_fill, separates clusters" {
    const mbrs = [_]BB{
        box(0, 0, 1, 1),    box(0, 0, 1, 1),
        box(20, 20, 21, 21), box(20, 20, 21, 21), box(20, 20, 21, 21),
    };
    var assign = [_]u8{9} ** 5;
    RStar.splitEntries(&mbrs, 2, &assign);
    var c0: usize = 0;
    for (assign) |a| {
        try testing.expect(a == 0 or a == 1);
        if (a == 0) c0 += 1;
    }
    try testing.expect(c0 >= 2 and (5 - c0) >= 2);
    // the two far-apart clusters must not be mixed
    try testing.expectEqual(assign[0], assign[1]);
    try testing.expectEqual(assign[2], assign[3]);
    try testing.expectEqual(assign[3], assign[4]);
    try testing.expect(assign[0] != assign[2]);
}

test "RStar reinsertOrder: farthest-from-center first" {
    const mbrs = [_]BB{
        box(0, 0, 1, 1), // center ~ (0,0)
        box(9, 9, 10, 10), // center ~ (9,9) -> farthest
        box(4, 4, 5, 5), // center ~ (4,4)
    };
    const node_mbr = box(0, 0, 10, 10); // center (5,5)
    var out = [_]usize{ 0, 0, 0 };
    RStar.reinsertOrder(&mbrs, node_mbr, &out);
    // index 1 (9,9) and index 0 (0,0) are farther from (5,5) than index 2 (4,4)
    try testing.expectEqual(@as(usize, 2), out[2]); // nearest is last
}

test "RStarTree: window query matches brute force after many inserts" {
    var m = try Model.init(testing.allocator);
    defer m.deinit();
    var t = RStarTree.init(&m);

    const N = 60;
    var boxes: [N]Key = undefined;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const x: i64 = @intCast((i * 7) % 25);
        const y: i64 = @intCast((i * 11) % 25);
        boxes[i] = box(x, y, x + 3, y + 3);
        try t.insert(boxes[i], @intCast(i));
    }
    try testing.expect((try t.height()) >= 2);

    const queries = [_]Key{ box(0, 0, 5, 5), box(10, 10, 20, 20), box(0, 0, 30, 30), box(24, 24, 28, 28) };
    for (queries) |q| {
        var got = Collector{};
        try t.search(q, &got, Collector.cb);
        i = 0;
        while (i < N) : (i += 1) {
            try testing.expectEqual(boxes[i].overlaps(&q), got.seen[i]);
        }
    }
}

test "RStarTree: forced reinsert loses no entries (full query returns all N)" {
    var m = try Model.init(testing.allocator);
    defer m.deinit();
    var t = RStarTree.init(&m);

    // 100 distinct values across a grid — heavy enough that leaf overflows (and
    // thus forced reinserts) happen many times.
    const N = 100;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const x: i64 = @intCast(i % 10);
        const y: i64 = @intCast(i / 10);
        try t.insert(box(x, y, x + 1, y + 1), @intCast(i));
    }

    var got = Collector{};
    try t.search(box(-1, -1, 100, 100), &got, Collector.cb);

    // every value present exactly once — no entry dropped or duplicated by the
    // reinsert/split machinery.
    try testing.expectEqual(@as(usize, N), got.count);
    i = 0;
    while (i < N) : (i += 1) {
        try testing.expect(got.seen[i]);
    }
}
