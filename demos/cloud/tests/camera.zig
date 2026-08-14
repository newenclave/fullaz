const std = @import("std");
const common = @import("common.zig");

const cloud = common.cloud;
const camera_mod = cloud.camera;
const constants = cloud.constants;
const Camera = camera_mod.Camera;
const Projector = camera_mod.Projector;
const Viewport = camera_mod.Viewport;

const testing = std.testing;

const distance: f64 = 1000.0;
const fov_y: f64 = 0.9;

// Looking down -Z from {0,0,distance} at the origin: right is +X, up is +Y.
fn axisAligned() Camera {
    return .{ .yaw = 0, .pitch = 0, .distance = distance, .target = .{ 0, 0, 0 } };
}

fn viewport(cell_aspect: f64) Viewport {
    return .{ .width = 800, .height = 600, .cell_aspect = cell_aspect, .fov_y = fov_y };
}

fn projector(cell_aspect: f64) Projector {
    const camera = axisAligned();
    return Projector.init(&camera, viewport(cell_aspect));
}

test "cloud: the camera sits one distance away along its direction" {
    const camera = axisAligned();
    const eye = camera.eye();

    try testing.expectApproxEqAbs(@as(f64, 0), eye[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), eye[1], 1e-9);
    try testing.expectApproxEqAbs(distance, eye[2], 1e-9);
}

test "cloud: the target projects to the centre of the viewport" {
    const p = projector(1.0);
    const centre = p.project(.{ 0, 0, 0 });

    try testing.expect(centre.visible);
    try testing.expectApproxEqAbs(@as(f64, 400), centre.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 300), centre.y, 1e-9);
    try testing.expectApproxEqAbs(distance, centre.depth, 1e-9);
}

// The half-angle of the vertical field of view must land exactly on the edge,
// which is what pins the focal length formula.
test "cloud: the edge of the vertical field of view lands on the top row" {
    const p = projector(1.0);
    const height = distance * @tan(fov_y * 0.5);

    const top = p.project(.{ 0, height, 0 });
    try testing.expect(top.visible);
    try testing.expectApproxEqAbs(@as(f64, 0), top.y, 1e-6);

    const bottom = p.project(.{ 0, -height, 0 });
    try testing.expectApproxEqAbs(@as(f64, 600), bottom.y, 1e-6);
}

test "cloud: screen y grows downwards" {
    const p = projector(1.0);

    const above = p.project(.{ 0, 100, 0 });
    const below = p.project(.{ 0, -100, 0 });
    try testing.expect(above.y < below.y);
}

test "cloud: a point behind the camera is dropped, not mirrored" {
    const p = projector(1.0);

    try testing.expect(!p.project(.{ 0, 0, 2 * distance }).visible);
    try testing.expect(!p.project(.{ 0, 0, distance + 1 }).visible);
    try testing.expect(p.project(.{ 0, 0, distance - 1 }).visible);
}

test "cloud: a point at the camera itself never yields a non-finite splat" {
    const p = projector(1.0);
    const at_eye = p.project(p.eye);

    try testing.expect(!at_eye.visible);
    try testing.expect(std.math.isFinite(at_eye.x));
    try testing.expect(std.math.isFinite(at_eye.y));
}

// `if (x < lo or x >= hi) return;` lets NaN straight through. The projector
// uses the positive form instead, so this has to hold.
test "cloud: projection rejects nan and infinite coordinates" {
    const p = projector(1.0);
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);

    try testing.expect(!p.project(.{ nan, 0, 0 }).visible);
    try testing.expect(!p.project(.{ 0, nan, 0 }).visible);
    try testing.expect(!p.project(.{ 0, 0, nan }).visible);
    try testing.expect(!p.project(.{ inf, 0, 0 }).visible);
    try testing.expect(!p.project(.{ 0, 0, -inf }).visible);
}

test "cloud: a full turn of yaw returns the same projection" {
    var camera = axisAligned();
    const before = Projector.init(&camera, viewport(1.0)).project(.{ 100, 50, 0 });

    camera.orbit(2 * std.math.pi, 0);
    const after = Projector.init(&camera, viewport(1.0)).project(.{ 100, 50, 0 });

    try testing.expectApproxEqAbs(before.x, after.x, 1e-6);
    try testing.expectApproxEqAbs(before.y, after.y, 1e-6);
}

test "cloud: pitch is clamped clear of the poles" {
    var camera = axisAligned();
    camera.orbit(0, 100);
    try testing.expect(camera.pitch < std.math.pi / 2.0);

    camera.orbit(0, -200);
    try testing.expect(camera.pitch > -std.math.pi / 2.0);
}

test "cloud: dolly is multiplicative, clamped and nan proof" {
    var camera = axisAligned();

    camera.dolly(2.0);
    try testing.expectApproxEqAbs(2 * distance, camera.distance, 1e-9);

    const before = camera.distance;
    camera.dolly(std.math.nan(f64));
    camera.dolly(-1.0);
    camera.dolly(0);
    try testing.expectEqual(before, camera.distance);

    camera.dolly(1e9);
    try testing.expect(camera.distance <= constants.root_side * 8.0);
    camera.dolly(1e-9);
    try testing.expect(camera.distance >= constants.root_side / 64.0);
}

test "cloud: a projected sphere halves when the distance doubles" {
    const p = projector(1.0);

    const near_size = p.pixelSize(10, 500);
    const far_size = p.pixelSize(10, 1000);

    try testing.expect(near_size > 0);
    try testing.expectApproxEqRel(near_size / 2.0, far_size, 1e-9);
}

test "cloud: pixel size is zero behind the camera" {
    const p = projector(1.0);

    try testing.expectEqual(@as(f64, 0), p.pixelSize(10, -1));
    try testing.expectEqual(@as(f64, 0), p.pixelSize(10, 0));
}

// Terminal cells are about twice as tall as wide, so the same angle has to
// cover twice as many cells horizontally or a sphere renders as an ellipse.
test "cloud: cell aspect keeps a circle round" {
    inline for (.{ 1.0, 2.0 }) |cell_aspect| {
        const p = projector(cell_aspect);

        var min_x: f64 = std.math.inf(f64);
        var max_x: f64 = -std.math.inf(f64);
        var min_y: f64 = std.math.inf(f64);
        var max_y: f64 = -std.math.inf(f64);

        var i: usize = 0;
        while (i < 64) : (i += 1) {
            const angle = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / 64.0;
            const projected = p.project(.{ 50 * @cos(angle), 50 * @sin(angle), 0 });
            try testing.expect(projected.visible);
            min_x = @min(min_x, projected.x);
            max_x = @max(max_x, projected.x);
            min_y = @min(min_y, projected.y);
            max_y = @max(max_y, projected.y);
        }

        const ratio = (max_x - min_x) / (max_y - min_y);
        try testing.expectApproxEqRel(@as(f64, cell_aspect), ratio, 0.1);
    }
}

test "cloud: culling keeps anything the camera is inside" {
    const p = projector(1.0);
    const around_eye = cloud.Box.create(
        .{ -2000, -2000, -2000 },
        .{ 2000, 2000, 2000 },
    );

    try testing.expect(!p.cullsBox(around_eye));
}

test "cloud: culling drops a box far off to the side" {
    const p = projector(1.0);
    const aside = cloud.Box.create(
        .{ 50_000, 0, -100 },
        .{ 50_100, 100, 0 },
    );

    try testing.expect(p.cullsBox(aside));
}

test "cloud: culling keeps a box in front of the camera" {
    const p = projector(1.0);
    const ahead = cloud.Box.create(
        .{ -100, -100, -100 },
        .{ 100, 100, 100 },
    );

    try testing.expect(!p.cullsBox(ahead));
}
