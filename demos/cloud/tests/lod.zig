const std = @import("std");
const common = @import("common.zig");

const cloud = common.cloud;
const constants = cloud.constants;
const lod = cloud.lod;
const Device = common.Device;
const PageCache = common.PageCache;
const C = cloud.Cloud(PageCache);

const testing = std.testing;

const points: u32 = 4000;
const spec = cloud.scene.Spec{ .seed = 0x10D7E57, .cluster_count = 6 };

const Fixture = struct {
    device: Device,
    cache: PageCache,
    c: C,

    fn init(self: *Fixture) !void {
        self.device = try Device.init(testing.allocator, common.block_size);
        errdefer self.device.deinit();
        self.cache = try PageCache.init(&self.device, testing.allocator, common.frames);
        errdefer self.cache.deinit();
        self.c = try C.format(testing.allocator, &self.cache, common.block_size, spec, points);
    }

    fn deinit(self: *Fixture) void {
        self.c.deinit();
        self.cache.deinit();
        self.device.deinit();
    }
};

// Far enough away that the whole cube is on screen, so nothing is culled.
fn wideCamera() cloud.camera.Camera {
    return .{
        .yaw = 0.6,
        .pitch = 0.35,
        .distance = constants.root_side * 3.0,
        .target = constants.worldCentre(),
    };
}

fn run(
    fixture: *Fixture,
    camera: cloud.camera.Camera,
    detail_pixels: f64,
    sink: anytype,
) !lod.Stats {
    var local = camera;
    const projector = cloud.camera.Projector.init(&local, .{ .width = 800, .height = 600 });
    // The tests speak in pixels because that is what is easy to reason about;
    // the viewport is 600 rows tall, so this is the matching fraction.
    return lod.collect(
        &fixture.c.tree,
        &projector,
        .{ .detail_fraction = detail_pixels / 600.0 },
        sink,
    );
}

// The single most valuable assertion in the demo. It catches a missing
// onInsert on an ancestor, a double count in onAdopt, a broken onGrow, an
// .accept that should have descended, and entries drawn under an accepted node.
test "cloud: every point is covered exactly once at any detail threshold" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const total: u64 = try fixture.c.pointCount();

    for ([_]f64{ 0.0, 0.5, 4.0, 12.0, 64.0, 1.0e6 }) |detail| {
        var sink = lod.CountingSink{};
        const stats = try run(&fixture, wideCamera(), detail, &sink);

        try testing.expectEqual(total, stats.coveredPoints());
        try testing.expectEqual(
            stats.nodes_accepted + @as(usize, @intCast(stats.points_visited)),
            stats.splats_emitted,
        );
        try testing.expectEqual(stats.splats_emitted, sink.pushes);
    }
}

test "cloud: the invariant still holds with the camera inside the cloud" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const total: u64 = try fixture.c.pointCount();
    const inside = cloud.camera.Camera{
        .yaw = 1.1,
        .pitch = -0.2,
        .distance = constants.root_side / 64.0,
        .target = constants.worldCentre(),
    };

    var sink = lod.CountingSink{};
    const stats = try run(&fixture, inside, 6.0, &sink);

    try testing.expectEqual(total, stats.coveredPoints());
    // Standing inside means most of the cube is off screen.
    try testing.expect(stats.nodes_culled > 0);
    try testing.expect(stats.culled_points > 0);
}

test "cloud: a huge threshold collapses the cloud to a single splat" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var sink = lod.CountingSink{};
    const stats = try run(&fixture, wideCamera(), 1.0e9, &sink);

    try testing.expectEqual(@as(usize, 1), stats.splats_emitted);
    try testing.expectEqual(@as(usize, 1), stats.nodes_accepted);
    try testing.expectEqual(@as(u64, 0), stats.points_visited);
    try testing.expectEqual(@as(u64, try fixture.c.pointCount()), stats.accepted_points);
}

test "cloud: a zero threshold draws every point individually" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var sink = lod.CountingSink{};
    const stats = try run(&fixture, wideCamera(), 0.0, &sink);

    try testing.expectEqual(@as(usize, 0), stats.nodes_accepted);
    try testing.expectEqual(@as(u64, 0), stats.accepted_points);
    try testing.expectEqual(@as(u64, try fixture.c.pointCount()), stats.points_visited);
}

// Catches an inverted comparison, the most common LOD mistake, without
// depending on any hardcoded splat count.
test "cloud: raising the threshold never increases the splat count" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var previous: usize = std.math.maxInt(usize);
    for ([_]f64{ 0.0, 1.0, 2.0, 4.0, 8.0, 16.0, 64.0, 256.0 }) |detail| {
        var sink = lod.CountingSink{};
        const stats = try run(&fixture, wideCamera(), detail, &sink);

        try testing.expect(stats.splats_emitted <= previous);
        previous = stats.splats_emitted;
    }
}

// The threshold is only meaningful next to the cloud's screen size. From
// wideCamera the whole cube spans about 200 px, so a leaf covering an eighth of
// it is still ~26 px and a 6 px threshold never aggregates anything. Pull back
// and the same threshold collapses the tree -- which is exactly the effect the
// viewer shows when you zoom out.
fn farCamera() cloud.camera.Camera {
    return .{
        .yaw = 0.6,
        .pitch = 0.35,
        .distance = constants.root_side * 24.0,
        .target = constants.worldCentre(),
    };
}

test "cloud: seen from far away, aggregates replace almost every point" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var sink = lod.CountingSink{};
    const stats = try run(&fixture, farCamera(), 16.0, &sink);

    // Measured on this fixture: 207 splats stand in for 4000 points, 3841 of
    // them through aggregates. Distance and threshold trade off directly --
    // 96x with a 4 px threshold gives the same numbers.
    try testing.expect(stats.nodes_accepted > 0);
    try testing.expect(stats.splats_emitted * 4 < points);
    try testing.expect(stats.accepted_points > stats.points_visited);
    // Still every point accounted for, just mostly through aggregates.
    try testing.expectEqual(@as(u64, try fixture.c.pointCount()), stats.coveredPoints());
}

const Recorder = struct {
    splats: std.ArrayList(lod.Splat) = .empty,
    allocator: std.mem.Allocator,

    fn deinit(self: *Recorder) void {
        self.splats.deinit(self.allocator);
    }

    pub fn push(self: *Recorder, splat: lod.Splat) void {
        self.splats.append(self.allocator, splat) catch unreachable;
    }
};

test "cloud: no splat is degenerate or non-finite" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var recorder = Recorder{ .allocator = testing.allocator };
    defer recorder.deinit();
    _ = try run(&fixture, wideCamera(), 6.0, &recorder);

    try testing.expect(recorder.splats.items.len > 0);
    for (recorder.splats.items) |splat| {
        try testing.expect(std.math.isFinite(splat.x));
        try testing.expect(std.math.isFinite(splat.y));
        try testing.expect(std.math.isFinite(splat.radius));
        try testing.expect(splat.depth > 0);
        try testing.expect(splat.radius > 0);
        try testing.expect(splat.count > 0);
    }
}

test "cloud: aggregates stand for more than one point, single points for one" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var recorder = Recorder{ .allocator = testing.allocator };
    defer recorder.deinit();
    const stats = try run(&fixture, wideCamera(), 6.0, &recorder);

    var aggregate_total: u64 = 0;
    var singles: usize = 0;
    for (recorder.splats.items) |splat| {
        if (splat.count == 1) {
            singles += 1;
        } else {
            aggregate_total += splat.count;
        }
    }

    try testing.expect(aggregate_total > 0);
    // Singles are the entries that were reached; aggregates cover the rest.
    try testing.expect(aggregate_total + singles <= try fixture.c.pointCount());
    try testing.expectEqual(stats.splats_emitted, recorder.splats.items.len);
}

test "cloud: traversal releases every frame it pins" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const available_before = fixture.cache.availableFrames();
    var sink = lod.CountingSink{};
    _ = try run(&fixture, wideCamera(), 6.0, &sink);

    try testing.expectEqual(available_before, fixture.cache.availableFrames());
}
