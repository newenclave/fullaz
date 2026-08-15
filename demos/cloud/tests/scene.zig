const std = @import("std");
const common = @import("common.zig");

const cloud = common.cloud;
const scene = cloud.scene;
const constants = cloud.constants;

const testing = std.testing;

const spec = scene.Spec{ .seed = 0x5EED1234, .cluster_count = 12 };
const sample_count: u32 = 2000;

test "cloud: sampling is a pure function of the index" {
    var index: u32 = 0;
    while (index < 64) : (index += 1) {
        const first = scene.sampleAt(spec, index);
        const second = scene.sampleAt(spec, index);

        try testing.expectEqual(first.position, second.position);
        try testing.expectEqualSlices(
            u8,
            &first.record.bytes(),
            &second.record.bytes(),
        );
    }
}

// Generation resumes from next_point_id after a reopen, so index n must not
// depend on how many samples were drawn before it.
test "cloud: sampling out of order matches sampling in order" {
    const forward = scene.sampleAt(spec, 1500);

    var index: u32 = 0;
    while (index < 1500) : (index += 1) {
        _ = scene.sampleAt(spec, index);
    }
    const after = scene.sampleAt(spec, 1500);

    try testing.expectEqual(forward.position, after.position);
}

test "cloud: a different seed produces a different scene" {
    const other = scene.Spec{ .seed = spec.seed + 1, .cluster_count = spec.cluster_count };
    var differing: usize = 0;

    var index: u32 = 0;
    while (index < 64) : (index += 1) {
        if (!std.meta.eql(scene.sampleAt(spec, index).position, scene.sampleAt(other, index).position)) {
            differing += 1;
        }
    }

    try testing.expectEqual(@as(usize, 64), differing);
}

// Growth is a real code path but not one the scene should ever trigger, so this
// is what keeps "every point lands inside the root cube" a checked invariant.
test "cloud: every sample lies strictly inside the root cube" {
    var index: u32 = 0;
    while (index < sample_count) : (index += 1) {
        const position = scene.sampleAt(spec, index).position;
        inline for (0..constants.dims) |axis| {
            try testing.expect(position[axis] > 0);
            try testing.expect(position[axis] < constants.root_side);
        }
    }
}

test "cloud: every sample coordinate is finite" {
    var index: u32 = 0;
    while (index < sample_count) : (index += 1) {
        const position = scene.sampleAt(spec, index).position;
        inline for (0..constants.dims) |axis| {
            try testing.expect(std.math.isFinite(position[axis]));
        }
    }
}

test "cloud: samples are distinct" {
    var seen = std.AutoHashMap([3]u32, void).init(testing.allocator);
    defer seen.deinit();

    var index: u32 = 0;
    while (index < sample_count) : (index += 1) {
        const position = scene.sampleAt(spec, index).position;
        const key: [3]u32 = .{
            @bitCast(position[0]),
            @bitCast(position[1]),
            @bitCast(position[2]),
        };
        try seen.put(key, {});
    }

    try testing.expectEqual(@as(usize, sample_count), seen.count());
}

// The whole point of the demo: dense cores next to near-empty space. If the
// density were uniform the octree would subdivide uniformly and show nothing.
test "cloud: clusters are much denser than the background" {
    var clustered: usize = 0;
    var background: usize = 0;

    var index: u32 = 0;
    while (index < sample_count) : (index += 1) {
        const record = scene.sampleAt(spec, index).record;
        if (record.cluster == scene.background_cluster) {
            background += 1;
        } else {
            clustered += 1;
        }
    }

    try testing.expectEqual(sample_count, clustered + background);
    // Around 15% background, with room for sampling noise.
    try testing.expect(background > sample_count / 10);
    try testing.expect(background < sample_count / 3);
}

test "cloud: cluster ids stay within the requested count" {
    var index: u32 = 0;
    while (index < sample_count) : (index += 1) {
        const record = scene.sampleAt(spec, index).record;
        if (record.cluster != scene.background_cluster) {
            try testing.expect(record.cluster < spec.cluster_count);
        }
        try testing.expectEqual(index, record.id.get());
    }
}

test "cloud: cluster centres sit clear of the walls" {
    var which: u16 = 0;
    while (which < scene.max_clusters) : (which += 1) {
        const cluster = scene.clusterAt(spec, which);
        try testing.expect(cluster.sigma > 0);
        inline for (0..constants.dims) |axis| {
            try testing.expect(cluster.center[axis] > 4 * cluster.sigma);
            try testing.expect(cluster.center[axis] < constants.root_side - 4 * cluster.sigma);
        }
    }
}
