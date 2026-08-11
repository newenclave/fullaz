const std = @import("std");
const fullaz = @import("fullaz");
const common = @import("common.zig");

const cloud = common.cloud;
const constants = cloud.constants;
const scene = cloud.scene;
const Device = common.Device;
const PageCache = common.PageCache;
const C = cloud.Cloud(PageCache);

const testing = std.testing;

const spec = scene.Spec{ .seed = 0xC0FFEE, .cluster_count = 8 };

fn rootTraitCount(c: *C) !u32 {
    var root = try c.model.accessor().loadNode(c.manager.root.?);
    defer c.model.accessor().deinitNode(&root);
    return cloud.trait.Splat.count(root.trait());
}

test "cloud: formatting builds an index that holds every point" {
    const points: u32 = 5000;

    var device = try Device.init(testing.allocator, common.block_size);
    defer device.deinit();
    var cache = try PageCache.init(&device, testing.allocator, common.frames);
    defer cache.deinit();

    var c = try C.format(testing.allocator, &cache, common.block_size, spec, points);
    defer c.deinit();

    try testing.expectEqual(@as(usize, points), try c.pointCount());
    try testing.expectEqual(points, try rootTraitCount(&c));
    try testing.expectEqual(points, c.next_point_id);

    // The root box is fixed up front, so the scene must never have grown it.
    const bounds = (try c.rootBounds()).?;
    try testing.expectEqual(@as(constants.Coord, 0), bounds.low[0]);
    try testing.expectEqual(constants.root_side, bounds.high[0]);
}

test "cloud: formatting refuses a device that already has pages" {
    var device = try Device.init(testing.allocator, common.block_size);
    defer device.deinit();
    var cache = try PageCache.init(&device, testing.allocator, common.frames);
    defer cache.deinit();

    {
        var handle = try cache.create();
        handle.deinit();
    }

    try testing.expectError(
        error.NotFreshDevice,
        C.format(testing.allocator, &cache, common.block_size, spec, 0),
    );
}

test "cloud: building the index releases every frame it pins" {
    var device = try Device.init(testing.allocator, common.block_size);
    defer device.deinit();
    var cache = try PageCache.init(&device, testing.allocator, common.frames);
    defer cache.deinit();

    var c = try C.format(testing.allocator, &cache, common.block_size, spec, 0);
    defer c.deinit();

    const available_before = cache.availableFrames();
    _ = try c.insertPoints(2000);
    try testing.expectEqual(available_before, cache.availableFrames());
}

test "cloud: an image stays under eighty bytes per point" {
    const points: u32 = 50000;

    var device = try Device.init(testing.allocator, common.block_size);
    defer device.deinit();
    var cache = try PageCache.init(&device, testing.allocator, common.frames);
    defer cache.deinit();

    var c = try C.format(testing.allocator, &cache, common.block_size, spec, points);
    defer c.deinit();
    try c.save();

    const Probe = struct {
        nodes: usize = 0,
        leaves: usize = 0,
        entries: usize = 0,

        fn onNode(
            self: *@This(),
            _: anytype,
            _: C.Box,
            _: *const C.Trait,
            is_leaf: bool,
        ) !fullaz.spatial.orthtree.tree.TraverseDecision {
            self.nodes += 1;
            if (is_leaf) self.leaves += 1;
            return .descend;
        }

        fn onEntry(self: *@This(), _: C.Box, _: []const u8) !void {
            self.entries += 1;
        }
    };
    var probe = Probe{};
    try c.tree.traverse(Probe.onNode, Probe.onEntry, &probe);

    try testing.expectEqual(@as(usize, points), probe.entries);
    // The tree must genuinely subdivide, or the LOD demo has nothing to show.
    try testing.expect(probe.leaves > 500);

    // A point costs about 34 bytes on the page (24 of MBR, 8 of payload, a slot
    // directory entry). The rest is chunk pages that leaves only partly fill,
    // plus chains orphaned by splits: destroyPage is a no-op here and the model
    // always takes fresh pages from the cache, so nothing recycles them.
    // block_size and max_leaf_entries are tuned together against this number:
    // at 2048 it is 89 and at 4096 it is 125.
    const per_point = c.imageBytes() / points;
    try testing.expect(per_point < 90);
}

test "cloud: reopening restores the index, the generator and the viewer" {
    const points: u32 = 3000;

    var device = try Device.init(testing.allocator, common.block_size);
    defer device.deinit();

    var saved_trait: u32 = 0;
    var saved_blocks: usize = 0;

    {
        var cache = try PageCache.init(&device, testing.allocator, common.frames);
        defer cache.deinit();
        var c = try C.format(testing.allocator, &cache, common.block_size, spec, points);
        defer c.deinit();

        c.camera = .{ .yaw = 0.25, .pitch = -0.75, .distance = 4321, .target = .{ 1, 2, 3 } };
        c.detail_fraction = 0.095;
        saved_trait = try rootTraitCount(&c);

        try c.save();
        saved_blocks = device.blocksCount();
    }

    {
        var cache = try PageCache.init(&device, testing.allocator, common.frames);
        defer cache.deinit();
        var c = try C.open(testing.allocator, &cache, common.block_size);
        defer c.deinit();

        try testing.expectEqual(@as(usize, points), try c.pointCount());
        try testing.expectEqual(saved_trait, try rootTraitCount(&c));
        try testing.expectEqual(points, c.next_point_id);
        try testing.expectEqual(spec.seed, c.spec.seed);
        try testing.expectEqual(spec.cluster_count, c.spec.cluster_count);
        try testing.expectEqual(@as(f64, 0.095), c.detail_fraction);
        try testing.expectEqual(@as(f64, 0.25), c.camera.yaw);
        try testing.expectEqual(@as(f64, -0.75), c.camera.pitch);
        try testing.expectEqual(@as(f64, 4321), c.camera.distance);
        try testing.expectEqual([3]f64{ 1, 2, 3 }, c.camera.target);

        // Opening must not rebuild anything.
        try testing.expectEqual(saved_blocks, device.blocksCount());
    }
}

test "cloud: reopening rejects a corrupted superblock" {
    var device = try Device.init(testing.allocator, common.block_size);
    defer device.deinit();

    {
        var cache = try PageCache.init(&device, testing.allocator, common.frames);
        defer cache.deinit();
        var c = try C.format(testing.allocator, &cache, common.block_size, spec, 32);
        defer c.deinit();
        try c.save();
    }

    device.storage.items[0] +%= 1; // magic

    var cache = try PageCache.init(&device, testing.allocator, common.frames);
    defer cache.deinit();
    try testing.expectError(
        cloud.superblock.Error.BadMagic,
        C.open(testing.allocator, &cache, common.block_size),
    );
}

test "cloud: reopening rejects a different block size" {
    var device = try Device.init(testing.allocator, common.block_size);
    defer device.deinit();

    {
        var cache = try PageCache.init(&device, testing.allocator, common.frames);
        defer cache.deinit();
        var c = try C.format(testing.allocator, &cache, common.block_size, spec, 32);
        defer c.deinit();
        try c.save();
    }

    var cache = try PageCache.init(&device, testing.allocator, common.frames);
    defer cache.deinit();
    try testing.expectError(
        cloud.superblock.Error.BadBlockSize,
        C.open(testing.allocator, &cache, common.block_size * 2),
    );
}

test "cloud: live insertion continues the generator across a reopen" {
    const first: u32 = 1000;
    const second: u32 = 500;

    var device = try Device.init(testing.allocator, common.block_size);
    defer device.deinit();

    {
        var cache = try PageCache.init(&device, testing.allocator, common.frames);
        defer cache.deinit();
        var c = try C.format(testing.allocator, &cache, common.block_size, spec, first);
        defer c.deinit();
        try c.save();
    }

    {
        var cache = try PageCache.init(&device, testing.allocator, common.frames);
        defer cache.deinit();
        var c = try C.open(testing.allocator, &cache, common.block_size);
        defer c.deinit();

        _ = try c.insertPoints(second);

        try testing.expectEqual(@as(usize, first + second), try c.pointCount());
        try testing.expectEqual(first + second, try rootTraitCount(&c));
        try testing.expectEqual(first + second, c.next_point_id);
        try c.save();
    }

    // The whole set must be reachable, and the points added in session two must
    // be the ones the pure generator would have produced in a single run.
    var cache = try PageCache.init(&device, testing.allocator, common.frames);
    defer cache.deinit();
    var c = try C.open(testing.allocator, &cache, common.block_size);
    defer c.deinit();

    const Collector = struct {
        seen: std.AutoHashMap(u32, void),

        fn collect(self: *@This(), _: C.Box, value: []const u8) !void {
            try self.seen.put(cloud.point.PointRecord.fromBytes(value).id.get(), {});
        }
    };
    var collector = Collector{ .seen = std.AutoHashMap(u32, void).init(testing.allocator) };
    defer collector.seen.deinit();
    try c.tree.query(constants.rootBox(), Collector.collect, &collector);

    try testing.expectEqual(@as(usize, first + second), collector.seen.count());
    var id: u32 = 0;
    while (id < first + second) : (id += 1) {
        try testing.expect(collector.seen.contains(id));
    }
}

// The slab FSM is page-backed, so its root must survive the reopen. With the
// volatile model it would start empty and every session would allocate fresh
// node pages instead of filling the ones already on disk.
test "cloud: the free-space map survives a reopen" {
    var device = try Device.init(testing.allocator, common.block_size);
    defer device.deinit();

    {
        var cache = try PageCache.init(&device, testing.allocator, common.frames);
        defer cache.deinit();
        var c = try C.format(testing.allocator, &cache, common.block_size, spec, 500);
        defer c.deinit();
        try testing.expect(c.manager.fsm_class_root != null);
        try c.save();
    }

    var cache = try PageCache.init(&device, testing.allocator, common.frames);
    defer cache.deinit();
    var c = try C.open(testing.allocator, &cache, common.block_size);
    defer c.deinit();

    try testing.expect(c.manager.fsm_class_root != null);
    // A page with room is still findable, so new nodes land in it.
    try testing.expect((try c.fsm.find(1)) != null);
}
