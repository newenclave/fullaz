const fullaz = @import("fullaz");
const std = @import("std");

const BoundingBox = fullaz.rtree.BoundingBox(i64, 2);
const BoundingBoxTree = fullaz.aabb_tree.Tree(BoundingBox, u64);

const TestBox = struct {
    pub const Coord = i64;

    low: Coord,
    high: Coord,

    fn init(low: Coord, high: Coord) TestBox {
        return .{ .low = low, .high = high };
    }

    pub fn merged(self: *const TestBox, other: *const TestBox) TestBox {
        return .{ .low = @min(self.low, other.low), .high = @max(self.high, other.high) };
    }

    pub fn overlaps(self: *const TestBox, other: *const TestBox) bool {
        return self.low < other.high and other.low < self.high;
    }

    pub fn containsBox(self: *const TestBox, other: *const TestBox) bool {
        return other.low >= self.low and other.high <= self.high;
    }

    pub fn perimeter(self: *const TestBox) Coord {
        return self.high - self.low;
    }

    pub fn expanded(self: *const TestBox, amount: Coord) TestBox {
        return .{ .low = self.low - amount, .high = self.high + amount };
    }
};

const TestTree = fullaz.aabb_tree.Tree(TestBox, u64);
const TestFatTree = fullaz.aabb_tree.FatTree(TestBox, u64, 5);

const QueryCtx = struct {
    values: std.ArrayList(u64) = .empty,

    fn deinit(self: *QueryCtx) void {
        self.values.deinit(std.testing.allocator);
    }
};

fn collectQuery(ctx: *QueryCtx, _: TestBox, value: u64) !void {
    try ctx.values.append(std.testing.allocator, value);
}

fn containsValue(values: []const u64, needle: u64) bool {
    for (values) |value| {
        if (value == needle) {
            return true;
        }
    }
    return false;
}

fn randomStressBox(rnd: std.Random) TestBox {
    const low = rnd.intRangeAtMost(i64, -500, 500);
    const width = rnd.intRangeAtMost(i64, 1, 80);
    return TestBox.init(low, low + width);
}

fn randomStressQuery(rnd: std.Random) TestBox {
    const low = rnd.intRangeAtMost(i64, -550, 550);
    const width = rnd.intRangeAtMost(i64, 1, 160);
    return TestBox.init(low, low + width);
}

fn verifyStressQuery(
    tree: anytype,
    objects: anytype,
    query: TestBox,
    seen: []bool,
    ctx: *QueryCtx,
    stack: anytype,
) !void {
    @memset(seen, false);
    ctx.values.clearRetainingCapacity();

    try tree.queryWithStack(query, std.testing.allocator, stack, ctx, collectQuery);

    for (ctx.values.items) |value| {
        const index: usize = @intCast(value);
        try std.testing.expect(index < objects.len);
        try std.testing.expect(!seen[index]);
        seen[index] = true;
    }

    var expected_count: usize = 0;
    for (objects, 0..) |object, index| {
        const expected = object.live and object.bbox.overlaps(&query);
        if (expected) {
            expected_count += 1;
        }
        try std.testing.expectEqual(expected, seen[index]);
    }
    try std.testing.expectEqual(expected_count, ctx.values.items.len);
}

fn runRandomStress(comptime TreeT: type, seed: u64) !void {
    const allocator = std.testing.allocator;
    const max_objects = 128;
    const operations = 1200;

    const Object = struct {
        id: TreeT.NodeId,
        bbox: TestBox,
        live: bool,
    };

    var tree = TreeT.init(allocator);
    defer tree.deinit();

    var objects: std.ArrayList(Object) = .empty;
    defer objects.deinit(allocator);
    try objects.ensureTotalCapacity(allocator, max_objects);

    var ctx = QueryCtx{};
    defer ctx.deinit();

    var stack: TreeT.QueryStack = .empty;
    defer stack.deinit(allocator);
    try stack.ensureTotalCapacity(allocator, 64);

    var seen: [max_objects]bool = undefined;
    var live_count: usize = 0;

    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();

    for (0..operations) |step| {
        const action = rnd.intRangeLessThan(u8, 0, 100);
        const can_insert = live_count < max_objects;

        if (can_insert and (live_count == 0 or action < 35)) {
            var slot = objects.items.len;
            for (objects.items, 0..) |object, index| {
                if (!object.live) {
                    slot = index;
                    break;
                }
            }

            const bbox = randomStressBox(rnd);
            const id = try tree.insert(bbox, @intCast(slot));
            if (slot == objects.items.len) {
                try objects.append(allocator, .{ .id = id, .bbox = bbox, .live = true });
            } else {
                objects.items[slot] = .{ .id = id, .bbox = bbox, .live = true };
            }
            live_count += 1;
        } else if (live_count > 0 and action < 60) {
            var slot = rnd.intRangeLessThan(usize, 0, objects.items.len);
            while (!objects.items[slot].live) {
                slot = rnd.intRangeLessThan(usize, 0, objects.items.len);
            }

            const bbox = randomStressBox(rnd);
            try tree.update(objects.items[slot].id, bbox);
            objects.items[slot].bbox = bbox;
        } else if (live_count > 0 and action < 75) {
            var slot = rnd.intRangeLessThan(usize, 0, objects.items.len);
            while (!objects.items[slot].live) {
                slot = rnd.intRangeLessThan(usize, 0, objects.items.len);
            }

            try tree.remove(objects.items[slot].id);
            try std.testing.expectError(TreeT.Error.InvalidNode, tree.getValue(objects.items[slot].id));
            objects.items[slot].live = false;
            live_count -= 1;
        } else {
            try verifyStressQuery(
                &tree,
                objects.items,
                randomStressQuery(rnd),
                seen[0..objects.items.len],
                &ctx,
                &stack,
            );
        }

        try std.testing.expectEqual(live_count, tree.count());
        if (step % 37 == 0) {
            try verifyStressQuery(
                &tree,
                objects.items,
                randomStressQuery(rnd),
                seen[0..objects.items.len],
                &ctx,
                &stack,
            );
        }
    }

    for (0..100) |_| {
        try verifyStressQuery(
            &tree,
            objects.items,
            randomStressQuery(rnd),
            seen[0..objects.items.len],
            &ctx,
            &stack,
        );
    }
}

test "aabb tree module imports" {
    _ = fullaz.aabb_tree;
}

test "aabb tree initializes empty" {
    var tree = BoundingBoxTree.init(std.testing.allocator);
    defer tree.deinit();

    try std.testing.expect(tree.empty());
    try std.testing.expectEqual(@as(usize, 0), tree.count());
}

test "aabb tree box contract accepts rtree bounding box" {
    comptime fullaz.aabb_tree.assertBox(BoundingBox);
}

test "aabb tree fat box contract accepts rtree bounding box" {
    comptime fullaz.aabb_tree.assertFatBox(BoundingBox);
}

test "aabb tree query on empty tree returns nothing" {
    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    var ctx = QueryCtx{};
    defer ctx.deinit();

    try tree.query(TestBox.init(0, 1), &ctx, collectQuery);
    try std.testing.expectEqual(@as(usize, 0), ctx.values.items.len);
}

test "aabb tree query returns matching leaves" {
    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    _ = try tree.insert(TestBox.init(0, 10), 100);
    _ = try tree.insert(TestBox.init(20, 30), 200);
    _ = try tree.insert(TestBox.init(25, 40), 300);

    var ctx = QueryCtx{};
    defer ctx.deinit();

    try tree.query(TestBox.init(24, 26), &ctx, collectQuery);
    try std.testing.expectEqual(@as(usize, 2), ctx.values.items.len);
    try std.testing.expect(containsValue(ctx.values.items, 200));
    try std.testing.expect(containsValue(ctx.values.items, 300));
}

test "aabb tree queryWithStack uses caller scratch stack" {
    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    _ = try tree.insert(TestBox.init(0, 10), 100);
    _ = try tree.insert(TestBox.init(20, 30), 200);
    _ = try tree.insert(TestBox.init(25, 40), 300);

    var stack: TestTree.QueryStack = .empty;
    defer stack.deinit(std.testing.allocator);
    try stack.ensureTotalCapacity(std.testing.allocator, 8);
    const capacity = stack.capacity;

    var ctx = QueryCtx{};
    defer ctx.deinit();

    try tree.queryWithStack(TestBox.init(24, 26), std.testing.allocator, &stack, &ctx, collectQuery);
    try std.testing.expectEqual(@as(usize, 0), stack.items.len);
    try std.testing.expectEqual(capacity, stack.capacity);
    try std.testing.expectEqual(@as(usize, 2), ctx.values.items.len);
    try std.testing.expect(containsValue(ctx.values.items, 200));
    try std.testing.expect(containsValue(ctx.values.items, 300));
}

test "aabb tree queryIds returns matching leaf ids" {
    const IdQueryCtx = struct {
        ids: std.ArrayList(TestTree.NodeId) = .empty,
        values: std.ArrayList(u64) = .empty,

        fn deinit(self: *@This()) void {
            self.values.deinit(std.testing.allocator);
            self.ids.deinit(std.testing.allocator);
        }

        fn collect(self: *@This(), id: TestTree.NodeId, _: TestBox, value: u64) !void {
            try self.ids.append(std.testing.allocator, id);
            try self.values.append(std.testing.allocator, value);
        }
    };

    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    _ = try tree.insert(TestBox.init(0, 10), 100);
    const second = try tree.insert(TestBox.init(20, 30), 200);
    const third = try tree.insert(TestBox.init(25, 40), 300);

    var ctx = IdQueryCtx{};
    defer ctx.deinit();

    try tree.queryIds(TestBox.init(24, 26), &ctx, IdQueryCtx.collect);
    try std.testing.expectEqual(@as(usize, 2), ctx.ids.items.len);
    try std.testing.expectEqual(@as(usize, 2), ctx.values.items.len);
    try std.testing.expect(containsValue(ctx.values.items, 200));
    try std.testing.expect(containsValue(ctx.values.items, 300));

    var saw_second = false;
    var saw_third = false;
    for (ctx.ids.items) |id| {
        saw_second = saw_second or (id.index == second.index and id.generation == second.generation);
        saw_third = saw_third or (id.index == third.index and id.generation == third.generation);
    }
    try std.testing.expect(saw_second);
    try std.testing.expect(saw_third);

    ctx.ids.clearRetainingCapacity();
    ctx.values.clearRetainingCapacity();

    var stack: TestTree.QueryStack = .empty;
    defer stack.deinit(std.testing.allocator);

    try tree.queryIdsWithStack(TestBox.init(21, 22), std.testing.allocator, &stack, &ctx, IdQueryCtx.collect);
    try std.testing.expectEqual(@as(usize, 1), ctx.ids.items.len);
    try std.testing.expectEqual(second, ctx.ids.items[0]);
    try std.testing.expectEqual(@as(u64, 200), ctx.values.items[0]);
}

test "aabb tree query skips non-overlapping leaves" {
    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    _ = try tree.insert(TestBox.init(0, 10), 100);
    _ = try tree.insert(TestBox.init(20, 30), 200);

    var ctx = QueryCtx{};
    defer ctx.deinit();

    try tree.query(TestBox.init(10, 20), &ctx, collectQuery);
    try std.testing.expectEqual(@as(usize, 0), ctx.values.items.len);
}

test "aabb tree remove only leaf empties tree" {
    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    const id = try tree.insert(TestBox.init(0, 10), 100);
    try tree.remove(id);

    try std.testing.expect(tree.empty());
    try std.testing.expectEqual(@as(usize, 0), tree.count());
    try std.testing.expectError(TestTree.Error.InvalidNode, tree.getValue(id));
}

test "aabb tree removed id stays invalid after slot reuse" {
    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    const old_id = try tree.insert(TestBox.init(0, 10), 100);
    try tree.remove(old_id);

    const new_id = try tree.insert(TestBox.init(20, 30), 200);

    try std.testing.expectEqual(old_id.index, new_id.index);
    try std.testing.expect(new_id.generation != old_id.generation);
    try std.testing.expectError(TestTree.Error.InvalidNode, tree.getValue(old_id));
    try std.testing.expectEqual(@as(u64, 200), try tree.getValue(new_id));
}

test "aabb tree remove refits ancestors and excludes removed value" {
    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    _ = try tree.insert(TestBox.init(0, 10), 100);
    const removed = try tree.insert(TestBox.init(20, 30), 200);
    _ = try tree.insert(TestBox.init(25, 40), 300);

    try tree.remove(removed);

    try std.testing.expectEqual(@as(usize, 2), tree.count());

    var ctx = QueryCtx{};
    defer ctx.deinit();

    try tree.query(TestBox.init(24, 26), &ctx, collectQuery);
    try std.testing.expectEqual(@as(usize, 1), ctx.values.items.len);
    try std.testing.expect(containsValue(ctx.values.items, 300));
}

test "aabb tree update keeps id and moves leaf into query" {
    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    const id = try tree.insert(TestBox.init(0, 10), 100);
    _ = try tree.insert(TestBox.init(20, 30), 200);

    try tree.update(id, TestBox.init(22, 24));

    try std.testing.expectEqual(@as(usize, 2), tree.count());
    try std.testing.expectEqual(TestBox.init(22, 24), try tree.getBox(id));
    try std.testing.expectEqual(TestBox.init(22, 24), try tree.getTreeBox(id));

    var ctx = QueryCtx{};
    defer ctx.deinit();

    try tree.query(TestBox.init(21, 25), &ctx, collectQuery);
    try std.testing.expectEqual(@as(usize, 2), ctx.values.items.len);
    try std.testing.expect(containsValue(ctx.values.items, 100));
    try std.testing.expect(containsValue(ctx.values.items, 200));
}

test "aabb tree update keeps id and moves leaf out of query" {
    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    const id = try tree.insert(TestBox.init(0, 10), 100);
    _ = try tree.insert(TestBox.init(20, 30), 200);

    try tree.update(id, TestBox.init(40, 50));

    var ctx = QueryCtx{};
    defer ctx.deinit();

    try tree.query(TestBox.init(0, 10), &ctx, collectQuery);
    try std.testing.expectEqual(@as(usize, 0), ctx.values.items.len);

    try tree.query(TestBox.init(45, 46), &ctx, collectQuery);
    try std.testing.expectEqual(@as(usize, 1), ctx.values.items.len);
    try std.testing.expect(containsValue(ctx.values.items, 100));
}

test "aabb tree update inside current box shrinks exact tree box" {
    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    const id = try tree.insert(TestBox.init(0, 100), 100);
    _ = try tree.insert(TestBox.init(200, 300), 200);

    try tree.update(id, TestBox.init(10, 20));

    try std.testing.expectEqual(TestBox.init(10, 20), try tree.getBox(id));
    try std.testing.expectEqual(TestBox.init(10, 20), try tree.getTreeBox(id));

    var ctx = QueryCtx{};
    defer ctx.deinit();

    try tree.query(TestBox.init(50, 60), &ctx, collectQuery);
    try std.testing.expectEqual(@as(usize, 0), ctx.values.items.len);

    try tree.query(TestBox.init(15, 16), &ctx, collectQuery);
    try std.testing.expectEqual(@as(usize, 1), ctx.values.items.len);
    try std.testing.expect(containsValue(ctx.values.items, 100));
}

test "aabb tree update works for root leaf" {
    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    const id = try tree.insert(TestBox.init(0, 10), 100);
    try tree.update(id, TestBox.init(20, 30));

    try std.testing.expectEqual(@as(usize, 1), tree.count());
    try std.testing.expectEqual(TestBox.init(20, 30), try tree.getBox(id));
    try std.testing.expectEqual(TestBox.init(20, 30), try tree.getTreeBox(id));
}

test "aabb tree balancing preserves query correctness" {
    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    for (0..64) |i| {
        const x: i64 = @intCast(i * 10);
        _ = try tree.insert(TestBox.init(x, x + 4), @intCast(i));
    }

    var ctx = QueryCtx{};
    defer ctx.deinit();

    try tree.query(TestBox.init(300, 315), &ctx, collectQuery);
    try std.testing.expectEqual(@as(usize, 2), ctx.values.items.len);
    try std.testing.expect(containsValue(ctx.values.items, 30));
    try std.testing.expect(containsValue(ctx.values.items, 31));
}

test "aabb tree accessors read and update leaf values" {
    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    const id = try tree.insert(TestBox.init(0, 10), 100);

    try std.testing.expectEqual(@as(u64, 100), try tree.getValue(id));
    try std.testing.expectEqual(TestBox.init(0, 10), try tree.getBox(id));
    try std.testing.expectEqual(TestBox.init(0, 10), try tree.getTreeBox(id));

    try tree.setValue(id, 200);
    try std.testing.expectEqual(@as(u64, 200), try tree.getValue(id));
}

test "aabb tree accessors reject invalid ids" {
    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    try std.testing.expectError(
        TestTree.Error.InvalidNode,
        tree.getValue(.{ .index = 0, .generation = 0 }),
    );
    try std.testing.expectError(
        TestTree.Error.InvalidNode,
        tree.getBox(.{ .index = 0, .generation = 0 }),
    );
    try std.testing.expectError(
        TestTree.Error.InvalidNode,
        tree.getTreeBox(.{ .index = 0, .generation = 0 }),
    );
    try std.testing.expectError(TestTree.Error.InvalidNode, tree.setValue(
        .{ .index = 0, .generation = 0 },
        100,
    ));
}

test "aabb tree clear empties tree and allows reuse" {
    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    const old_id = try tree.insert(TestBox.init(0, 10), 100);
    _ = try tree.insert(TestBox.init(20, 30), 200);

    tree.clear();

    try std.testing.expect(tree.empty());
    try std.testing.expectEqual(@as(usize, 0), tree.count());
    try std.testing.expectError(TestTree.Error.InvalidNode, tree.getValue(old_id));

    const new_id = try tree.insert(TestBox.init(40, 50), 300);
    try std.testing.expectError(TestTree.Error.InvalidNode, tree.getValue(old_id));
    try std.testing.expectEqual(@as(u64, 300), try tree.getValue(new_id));
}

test "aabb fat tree stores expanded tree box and returns exact box" {
    var tree = TestFatTree.init(std.testing.allocator);
    defer tree.deinit();

    const id = try tree.insert(TestBox.init(10, 20), 100);

    try std.testing.expectEqual(TestBox.init(10, 20), try tree.getBox(id));
    try std.testing.expectEqual(TestBox.init(5, 25), try tree.getTreeBox(id));
}

test "aabb fat tree query filters fat-only overlaps" {
    var tree = TestFatTree.init(std.testing.allocator);
    defer tree.deinit();

    _ = try tree.insert(TestBox.init(10, 20), 100);

    var ctx = QueryCtx{};
    defer ctx.deinit();

    try tree.query(TestBox.init(6, 9), &ctx, collectQuery);
    try std.testing.expectEqual(@as(usize, 0), ctx.values.items.len);

    try tree.query(TestBox.init(12, 14), &ctx, collectQuery);
    try std.testing.expectEqual(@as(usize, 1), ctx.values.items.len);
    try std.testing.expect(containsValue(ctx.values.items, 100));
}

test "aabb fat tree update inside fat box keeps tree box" {
    var tree = TestFatTree.init(std.testing.allocator);
    defer tree.deinit();

    const id = try tree.insert(TestBox.init(10, 20), 100);
    _ = try tree.insert(TestBox.init(100, 110), 200);
    const old_tree_box = try tree.getTreeBox(id);

    try tree.update(id, TestBox.init(12, 22));

    try std.testing.expectEqual(old_tree_box, try tree.getTreeBox(id));
    try std.testing.expectEqual(TestBox.init(12, 22), try tree.getBox(id));

    var ctx = QueryCtx{};
    defer ctx.deinit();

    try tree.query(TestBox.init(10, 11), &ctx, collectQuery);
    try std.testing.expectEqual(@as(usize, 0), ctx.values.items.len);

    try tree.query(TestBox.init(21, 22), &ctx, collectQuery);
    try std.testing.expectEqual(@as(usize, 1), ctx.values.items.len);
    try std.testing.expect(containsValue(ctx.values.items, 100));
}

test "aabb fat tree update outside fat box reinserts with expanded tree box" {
    var tree = TestFatTree.init(std.testing.allocator);
    defer tree.deinit();

    const id = try tree.insert(TestBox.init(10, 20), 100);
    _ = try tree.insert(TestBox.init(100, 110), 200);

    try tree.update(id, TestBox.init(40, 50));

    try std.testing.expectEqual(TestBox.init(40, 50), try tree.getBox(id));
    try std.testing.expectEqual(TestBox.init(35, 55), try tree.getTreeBox(id));
}

test "aabb tree randomized operations match brute force oracle" {
    try runRandomStress(TestTree, 0xAABB_7EEE_2026);
}

test "aabb fat tree randomized operations match brute force oracle" {
    try runRandomStress(fullaz.aabb_tree.FatTree(TestBox, u64, 7), 0xFA7_AABB_2026);
}
