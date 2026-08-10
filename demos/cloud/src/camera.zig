const std = @import("std");
const constants = @import("constants.zig");
const point = @import("point.zig");

const Vec3d = point.Vec3d;
const Box = constants.Box;

// Keeping the camera off the poles keeps the right vector well defined.
const pitch_limit: f64 = std.math.pi / 2.0 - 1e-3;

// Also the persisted record: cloud.save writes these four fields verbatim.
pub const Camera = struct {
    yaw: f64,
    pitch: f64,
    distance: f64,
    target: Vec3d,

    pub fn orbit(self: *Camera, dyaw: f64, dpitch: f64) void {
        self.yaw += dyaw;
        self.pitch = std.math.clamp(self.pitch + dpitch, -pitch_limit, pitch_limit);
    }

    pub fn dolly(self: *Camera, factor: f64) void {
        if (!(factor > 0) or !std.math.isFinite(factor)) return;
        self.distance = std.math.clamp(
            self.distance * factor,
            constants.root_side / 64.0,
            constants.root_side * 8.0,
        );
    }

    // Unit vector from the target towards the eye. Axis 1 is up.
    pub fn direction(self: *const Camera) Vec3d {
        const cp = @cos(self.pitch);
        return .{
            cp * @sin(self.yaw),
            @sin(self.pitch),
            cp * @cos(self.yaw),
        };
    }

    pub fn eye(self: *const Camera) Vec3d {
        const dir = self.direction();
        return .{
            self.target[0] + dir[0] * self.distance,
            self.target[1] + dir[1] * self.distance,
            self.target[2] + dir[2] * self.distance,
        };
    }
};

pub const Viewport = struct {
    width: u32,
    height: u32,
    // Cell height divided by cell width. A canvas pixel is square (1.0); a
    // terminal cell is about twice as tall as it is wide (2.0). Without this
    // the same detail threshold means different things in the two front ends
    // and a sphere renders as an ellipse.
    cell_aspect: f64 = 1.0,
    fov_y: f64 = 0.9,
};

pub const Projected = struct {
    x: f64,
    y: f64,
    depth: f64,
    visible: bool,

    pub const hidden = Projected{ .x = 0, .y = 0, .depth = 0, .visible = false };
};

fn dot(a: Vec3d, b: Vec3d) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn cross(a: Vec3d, b: Vec3d) Vec3d {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn normalized(v: Vec3d) Vec3d {
    const length = @sqrt(dot(v, v));
    if (!(length > 0)) return .{ 0, 0, 1 };
    return .{ v[0] / length, v[1] / length, v[2] / length };
}

pub const Projector = struct {
    const Self = @This();

    eye: Vec3d,
    right: Vec3d,
    up: Vec3d,
    forward: Vec3d,
    focal_x: f64,
    focal_y: f64,
    half_w: f64,
    half_h: f64,
    width: f64,
    height: f64,
    near: f64,

    pub fn init(camera: *const Camera, viewport: Viewport) Self {
        const dir = camera.direction();
        const forward: Vec3d = .{ -dir[0], -dir[1], -dir[2] };
        const right = normalized(cross(forward, .{ 0, 1, 0 }));
        const up = cross(right, forward);

        const height: f64 = @floatFromInt(@max(viewport.height, 1));
        const width: f64 = @floatFromInt(@max(viewport.width, 1));
        const focal_y = (height * 0.5) / @tan(viewport.fov_y * 0.5);

        return .{
            .eye = camera.eye(),
            .right = right,
            .up = up,
            .forward = forward,
            // A horizontal angle needs cell_aspect times as many cells,
            // because each cell covers that much less width.
            .focal_x = focal_y * viewport.cell_aspect,
            .focal_y = focal_y,
            .half_w = width * 0.5,
            .half_h = height * 0.5,
            .width = width,
            .height = height,
            .near = constants.root_side * 1e-6,
        };
    }

    pub fn toView(self: *const Self, world: Vec3d) Vec3d {
        const d: Vec3d = .{
            world[0] - self.eye[0],
            world[1] - self.eye[1],
            world[2] - self.eye[2],
        };
        return .{ dot(d, self.right), dot(d, self.up), dot(d, self.forward) };
    }

    pub fn project(self: *const Self, world: Vec3d) Projected {
        const view = self.toView(world);
        // Positive form throughout: a NaN coordinate answers "hidden" rather
        // than sliding through the comparison the way `z < near` would.
        if (!(view[2] > self.near)) return Projected.hidden;

        const x = self.half_w + view[0] * self.focal_x / view[2];
        const y = self.half_h - view[1] * self.focal_y / view[2];
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return Projected.hidden;

        return .{ .x = x, .y = y, .depth = view[2], .visible = true };
    }

    // Screen diameter of a world-space sphere. The LOD test and the splat
    // radius both call this, so the two cannot disagree.
    pub fn pixelSize(self: *const Self, radius: f64, depth: f64) f64 {
        if (!(depth > self.near) or !(radius >= 0)) return 0;
        return 2.0 * radius * @max(self.focal_x, self.focal_y) / depth;
    }

    // Conservative: never culls a box that still has something visible in it.
    pub fn cullsBox(self: *const Self, box: Box) bool {
        const centre = point.boxCenter(box);
        const radius = point.boxRadius(box);
        const view = self.toView(centre);

        if (!(view[2] - radius > self.near)) {
            // The camera sits inside or behind the box; there is nothing
            // meaningful to project, so keep it.
            return false;
        }

        const screen_radius = self.pixelSize(radius, view[2] - radius) * 0.5;
        const x = self.half_w + view[0] * self.focal_x / view[2];
        const y = self.half_h - view[1] * self.focal_y / view[2];
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return false;

        if (x + screen_radius < 0 or x - screen_radius > self.width) return true;
        if (y + screen_radius < 0 or y - screen_radius > self.height) return true;
        return false;
    }
};
