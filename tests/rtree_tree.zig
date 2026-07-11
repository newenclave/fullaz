const std = @import("std");
const fullaz = @import("fullaz");
const rtree = fullaz.rtree;

const testing = std.testing;

const Model = rtree.models.Memory(i64, 2, u64, 4); // max_entries = 4
const Key = Model.KeyType;
const Tree = rtree.RTree(Model);

fn box(x0: i64, y0: i64, x1: i64, y1: i64) Key {
    return Key.initWith(.{ x0, y0 }, .{ x1, y1 });
}

const Collector = struct {
    seen: [128]bool = [_]bool{false} ** 128,
    count: usize = 0,
    fn cb(self: *Collector, _: Key, value: u64) anyerror!void {
        self.seen[value] = true;
        self.count += 1;
    }
};

test "RTree: empty tree search yields nothing" {
    var m = try Model.init(testing.allocator);
    defer m.deinit();
    var t = Tree.init(&m);

    var got = Collector{};
    try t.search(box(0, 0, 100, 100), &got, Collector.cb);
    try testing.expectEqual(@as(usize, 0), got.count);
    try testing.expectEqual(@as(usize, 0), try t.height());
}

test "RTree: single insert is findable" {
    var m = try Model.init(testing.allocator);
    defer m.deinit();
    var t = Tree.init(&m);

    try t.insert(box(2, 2, 4, 4), 7);

    var hit = Collector{};
    try t.search(box(3, 3, 3, 3), &hit, Collector.cb);
    try testing.expect(hit.seen[7]);

    var miss = Collector{};
    try t.search(box(50, 50, 60, 60), &miss, Collector.cb);
    try testing.expectEqual(@as(usize, 0), miss.count);
}

test "RTree: window query matches brute force after many inserts + splits" {
    var m = try Model.init(testing.allocator);
    defer m.deinit();
    var t = Tree.init(&m);

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
            const expected = boxes[i].overlaps(&q);
            try testing.expectEqual(expected, got.seen[i]);
        }
    }
}
