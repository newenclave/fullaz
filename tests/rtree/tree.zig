const std = @import("std");
const fullaz = @import("fullaz");
const rtree = fullaz.spatial.rtree;

const testing = std.testing;

const Model = rtree.models.Memory(i64, 2, u64, 4); // max_entries = 4
const Key = Model.KeyType;
const Tree = rtree.RTree(Model);
const FatTree = rtree.FatRTree(Model, 10);

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

test "RTree: extreme integer boxes split without metric overflow" {
    var m = try Model.init(testing.allocator);
    defer m.deinit();
    var t = Tree.init(&m);

    const extreme = box(
        std.math.minInt(i64),
        std.math.minInt(i64),
        std.math.maxInt(i64),
        std.math.maxInt(i64),
    );
    for (0..5) |index| {
        try t.insert(extreme, @intCast(index));
    }

    var found = Collector{};
    try t.search(extreme, &found, Collector.cb);
    try testing.expectEqual(@as(usize, 5), found.count);
    for (0..5) |index| {
        try testing.expect(found.seen[index]);
    }
}

test "RTree: searchIntersecting includes touching boxes" {
    var m = try Model.init(testing.allocator);
    defer m.deinit();
    var t = Tree.init(&m);

    try t.insert(box(0, 0, 10, 10), 7);

    const query = box(10, 2, 20, 8);
    var overlap_hits = Collector{};
    try t.search(query, &overlap_hits, Collector.cb);
    try testing.expectEqual(@as(usize, 0), overlap_hits.count);

    var intersection_hits = Collector{};
    try t.searchIntersecting(query, &intersection_hits, Collector.cb);
    try testing.expect(intersection_hits.seen[7]);
    try testing.expectEqual(@as(usize, 1), intersection_hits.count);
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

        var intersecting = Collector{};
        try t.searchIntersecting(q, &intersecting, Collector.cb);
        i = 0;
        while (i < N) : (i += 1) {
            const expected = boxes[i].intersects(&q);
            try testing.expectEqual(expected, intersecting.seen[i]);
        }
    }
}

test "FatRTree: inode MBR contains child MBR with the configured margin" {
    var m = try Model.init(testing.allocator);
    defer m.deinit();
    var t = FatTree.init(&m);

    for (0..5) |i| {
        const x: i64 = @intCast(i * 10);
        try t.insert(box(x, 0, x + 2, 2), @intCast(i));
    }

    const acc = m.accessor();
    const root = acc.getRoot().?;
    try testing.expect(!(try acc.isLeafId(root)));
    var inode = (try acc.loadInode(root)).?;
    defer acc.deinitInode(inode);

    const child_id = try inode.getChild(0);
    var leaf = (try acc.loadLeaf(child_id)).?;
    defer acc.deinitLeaf(leaf);

    const child_mbr = try leaf.nodeMbr();
    const stored_mbr = try inode.getMbr(0);
    try testing.expect(stored_mbr.containsBox(&child_mbr));
    try testing.expectEqual(child_mbr.low[0] - 10, stored_mbr.low[0]);
    try testing.expectEqual(child_mbr.high[0] + 10, stored_mbr.high[0]);
}

test "FatRTree: window query matches brute force after many inserts + splits" {
    var m = try Model.init(testing.allocator);
    defer m.deinit();
    var t = FatTree.init(&m);

    const N = 60;
    var boxes: [N]Key = undefined;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const x: i64 = @intCast((i * 7) % 25);
        const y: i64 = @intCast((i * 11) % 25);
        boxes[i] = box(x, y, x + 3, y + 3);
        try t.insert(boxes[i], @intCast(i));
    }

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
