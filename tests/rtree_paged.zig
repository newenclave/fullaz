const std = @import("std");
const fullaz = @import("fullaz");
const rtree = fullaz.rtree;
const dev = fullaz.device;
const PageCacheT = fullaz.storage.page_cache.PageCache;

const testing = std.testing;

const Device = dev.MemoryBlock(u32);
const PageCache = PageCacheT(Device);

const NoneStorageManager = struct {
    pub const PageId = u32;
    pub const Error = error{};
    root: ?u32 = null,

    pub fn getRoot(self: *const @This()) ?u32 {
        return self.root;
    }
    pub fn setRoot(self: *@This(), r: ?u32) Error!void {
        self.root = r;
    }
    pub fn destroyPage(_: *@This(), _: PageId) Error!void {}
};

// CoordT = i64, dims = 2, max_entries = 4, max_value = 32 bytes, little-endian.
const Model = rtree.models.Paged(PageCache, NoneStorageManager, i64, 2, 4, 32, .little);
const Key = Model.KeyType;

comptime {
    rtree.models.interfaces.assertModel(Model);
}

fn box(x0: i64, y0: i64, x1: i64, y1: i64) Key {
    return Key.initWith(.{ x0, y0 }, .{ x1, y1 });
}

const Collector = struct {
    seen: [128]bool = [_]bool{false} ** 128,
    count: usize = 0,
    fn cb(self: *Collector, _: Key, value: []const u8) anyerror!void {
        const i = std.mem.readInt(u32, value[0..4], .little);
        self.seen[i] = true;
        self.count += 1;
    }
};

fn insertIdx(t: anytype, mbr: Key, i: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, i, .little);
    try t.insert(mbr, &buf);
}

const MatchIdx = struct {
    want: u32,
    fn call(self: *const MatchIdx, _: Key, value: []const u8) bool {
        return std.mem.readInt(u32, value[0..4], .little) == self.want;
    }
};

test "RTree paged: empty tree search yields nothing" {
    const allocator = testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 16);
    defer cache.deinit();
    var store_mgr = NoneStorageManager{};
    var model = Model.init(&cache, &store_mgr, .{});

    var t = rtree.RTree(Model).init(&model);

    var got = Collector{};
    try t.search(box(0, 0, 100, 100), &got, Collector.cb);
    try testing.expectEqual(@as(usize, 0), got.count);
    try testing.expectEqual(@as(usize, 0), try t.height());
}

test "RTree paged: single insert is findable" {
    const allocator = testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 16);
    defer cache.deinit();
    var store_mgr = NoneStorageManager{};
    var model = Model.init(&cache, &store_mgr, .{});

    var t = rtree.RTree(Model).init(&model);
    try insertIdx(&t, box(2, 2, 4, 4), 7);

    var hit = Collector{};
    try t.search(box(3, 3, 3, 3), &hit, Collector.cb);
    try testing.expect(hit.seen[7]);

    var miss = Collector{};
    try t.search(box(50, 50, 60, 60), &miss, Collector.cb);
    try testing.expectEqual(@as(usize, 0), miss.count);
}

fn windowQueryMatchesBruteForce(comptime TreeT: type) !void {
    const allocator = testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 32);
    defer cache.deinit();
    var store_mgr = NoneStorageManager{};
    var model = Model.init(&cache, &store_mgr, .{});

    const available_before = cache.availableFrames();

    var t = TreeT.init(&model);

    const N = 60;
    var boxes: [N]Key = undefined;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const x: i64 = @intCast((i * 7) % 25);
        const y: i64 = @intCast((i * 11) % 25);
        boxes[i] = box(x, y, x + 3, y + 3);
        try insertIdx(&t, boxes[i], @intCast(i));
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

    // Every handle taken during the run must have been released.
    try testing.expectEqual(available_before, cache.availableFrames());
}

test "RTree paged: window query matches brute force after many inserts + splits" {
    try windowQueryMatchesBruteForce(rtree.RTree(Model));
}

test "RStarTree paged: window query matches brute force after many inserts + splits" {
    try windowQueryMatchesBruteForce(rtree.RStarTree(Model));
}

test "RTree paged: delete keeps the exact remaining set" {
    const allocator = testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 32);
    defer cache.deinit();
    var store_mgr = NoneStorageManager{};
    var model = Model.init(&cache, &store_mgr, .{});

    var t = rtree.RTree(Model).init(&model);

    const N = 40;
    var boxes: [N]Key = undefined;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const x: i64 = @intCast((i * 3) % 20);
        const y: i64 = @intCast((i * 5) % 20);
        boxes[i] = box(x, y, x + 2, y + 2);
        try insertIdx(&t, boxes[i], @intCast(i));
    }

    // Remove every third entry.
    var removed = [_]bool{false} ** N;
    i = 0;
    while (i < N) : (i += 3) {
        const m = MatchIdx{ .want = @intCast(i) };
        const ok = try t.remove(boxes[i], &m, MatchIdx.call);
        try testing.expect(ok);
        removed[i] = true;
    }

    // A full-window query must return exactly the survivors.
    var got = Collector{};
    try t.search(box(-100, -100, 100, 100), &got, Collector.cb);
    i = 0;
    while (i < N) : (i += 1) {
        try testing.expectEqual(!removed[i], got.seen[i]);
    }
}

test "RTree paged: state persists across a cache reopen (device round-trip)" {
    const allocator = testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var store_mgr = NoneStorageManager{};

    const N = 50;
    var boxes: [N]Key = undefined;

    // First session: fill the tree, then flush every page to the device.
    {
        var cache = try PageCache.init(&device, allocator, 32);
        defer cache.deinit();
        var model = Model.init(&cache, &store_mgr, .{});
        var t = rtree.RTree(Model).init(&model);

        var i: usize = 0;
        while (i < N) : (i += 1) {
            const x: i64 = @intCast((i * 13) % 30);
            const y: i64 = @intCast((i * 17) % 30);
            boxes[i] = box(x, y, x + 4, y + 4);
            try insertIdx(&t, boxes[i], @intCast(i));
        }
        try cache.flushAll();
    }

    // Second session: a brand new cache over the same device + same root.
    {
        var cache = try PageCache.init(&device, allocator, 32);
        defer cache.deinit();
        var model = Model.init(&cache, &store_mgr, .{});
        var t = rtree.RTree(Model).init(&model);

        const queries = [_]Key{
            box(0, 0, 10, 10),
            box(15, 15, 25, 25),
            box(-5, -5, 40, 40),
        };
        for (queries) |q| {
            var got = Collector{};
            try t.search(q, &got, Collector.cb);
            var i: usize = 0;
            while (i < N) : (i += 1) {
                try testing.expectEqual(boxes[i].overlaps(&q), got.seen[i]);
            }
        }
    }
}
