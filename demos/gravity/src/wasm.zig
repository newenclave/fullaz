const std = @import("std");
const fullaz = @import("fullaz");
const gravity = @import("gravity");

pub const panic = std.debug.FullPanic(struct {
    fn f(_: []const u8, _: ?usize) noreturn {
        @trap();
    }
}.f);

const allocator = std.heap.wasm_allocator;
const max_bodies = 1_001;
const max_regions = 512;

var bodies: std.ArrayList(gravity.Body) = .empty;
var simulation: gravity.Simulation = undefined;
var ready = false;
var config = gravity.Config{};
var steps: u32 = 0;
var lock_camera_to_center = false;

// Each body occupies four f32s: normalized x and y, relative mass, and whether
// it is the central mass. The browser reads the buffer from linear memory.
var particles: [max_bodies * 4]f32 = undefined;
var particle_count: usize = 0;
var regions: [max_regions * 4]f32 = undefined;
var region_count: usize = 0;
var camera_low: gravity.Point = .{ 0, 0 };
var camera_high: gravity.Point = .{ 0, 0 };

fn teardown() void {
    if (!ready) return;
    simulation.deinit();
    bodies.deinit(allocator);
    bodies = .empty;
    particle_count = 0;
    region_count = 0;
    ready = false;
}

fn refreshParticles() void {
    if (!ready or bodies.items.len == 0) return;

    var low = bodies.items[0].position;
    var high = low;
    for (bodies.items[1..]) |body| {
        low[0] = @min(low[0], body.position[0]);
        low[1] = @min(low[1], body.position[1]);
        high[0] = @max(high[0], body.position[0]);
        high[1] = @max(high[1], body.position[1]);
    }
    if (lock_camera_to_center) {
        const center = bodies.items[0].position;
        var radius: f64 = 10;
        for (bodies.items) |body| {
            radius = @max(radius, @abs(body.position[0] - center[0]));
            radius = @max(radius, @abs(body.position[1] - center[1]));
        }
        radius *= 1.1;
        low = .{ center[0] - radius, center[1] - radius };
        high = .{ center[0] + radius, center[1] + radius };
    } else {
        inline for (0..2) |axis| {
            const span = @max(high[axis] - low[axis], 20.0);
            const padding = span * 0.1;
            low[axis] -= padding;
            high[axis] += padding;
        }
    }
    camera_low = low;
    camera_high = high;

    const span_x = high[0] - low[0];
    const span_y = high[1] - low[1];
    particle_count = @min(bodies.items.len, max_bodies);
    for (bodies.items[0..particle_count], 0..) |body, index| {
        const i = index * 4;
        particles[i] = @floatCast((body.position[0] - low[0]) / span_x);
        particles[i + 1] = @floatCast((body.position[1] - low[1]) / span_y);
        particles[i + 2] = @floatCast(@sqrt(body.mass));
        particles[i + 3] = if (body.id == 0) 1 else if (body.id == 1) 2 else 0;
    }
}

// Barnes-Hut accepts different nodes for each target body. The browser renders
// the accepted nodes for body #1, so the visible regions correspond to actual
// aggregate-force decisions rather than merely the tree's full partition.
fn refreshRegions() void {
    region_count = 0;
    if (!ready or bodies.items.len == 0) return;

    const target = bodies.items[@min(@as(usize, 1), bodies.items.len - 1)];
    const Context = struct {
        target: gravity.Body,

        fn onNode(
            ctx: *@This(),
            _: usize,
            bounds: gravity.Box,
            trait: *const gravity.Trait,
            _: bool,
        ) !fullaz.spatial.orthtree.tree.TraverseDecision {
            const data = trait.data;
            if (data.total_mass == 0) return .descend;

            const center = gravity.centerOfMass(data);
            const dx = center[0] - ctx.target.position[0];
            const dy = center[1] - ctx.target.position[1];
            const distance = @sqrt(dx * dx + dy * dy);
            const width = @max(bounds.high[0] - bounds.low[0], bounds.high[1] - bounds.low[1]);
            const target_bounds = gravity.bodyBounds(ctx.target);
            if (bounds.containsBox(&target_bounds) or distance == 0 or width / distance >= config.theta) {
                return .descend;
            }

            if (region_count < max_regions) {
                const span_x = camera_high[0] - camera_low[0];
                const span_y = camera_high[1] - camera_low[1];
                const i = region_count * 4;
                regions[i] = @floatCast((bounds.low[0] - camera_low[0]) / span_x);
                regions[i + 1] = @floatCast((bounds.low[1] - camera_low[1]) / span_y);
                regions[i + 2] = @floatCast((bounds.high[0] - camera_low[0]) / span_x);
                regions[i + 3] = @floatCast((bounds.high[1] - camera_low[1]) / span_y);
                region_count += 1;
            }
            return .accept;
        }

        fn onEntry(_: *@This(), _: gravity.Box, _: gravity.Body) !void {}
    };

    var context = Context{ .target = target };
    simulation.tree.traverse(Context.onNode, Context.onEntry, &context) catch @trap();
}

export fn init(seed: u32, orbiting_body_count: u32, central_mass: f64) void {
    teardown();
    const count = @min(@as(usize, orbiting_body_count), max_bodies - 1);
    const mass = if (std.math.isFinite(central_mass) and central_mass > 0) central_mass else 100_000_000.0;
    bodies = gravity.makeGalaxy(allocator, .{
        .body_count = count,
        .seed = seed,
        .central_mass = mass,
    }) catch @trap();
    simulation = gravity.Simulation.init(allocator, bodies.items) catch @trap();
    // The terminal example uses dt=0.01 at 60 Hz. Browsers redraw much more
    // smoothly, so a smaller step keeps orbits readable at the web cadence.
    config = .{ .time_step = 0.002 };
    steps = 0;
    ready = true;
    refreshParticles();
    refreshRegions();
}

export fn advance(frame_count: u32) void {
    if (!ready) return;
    const count = @min(frame_count, 1_000);
    for (0..count) |_| {
        simulation.advance(bodies.items, config) catch @trap();
        steps +%= 1;
    }
    refreshParticles();
    refreshRegions();
}

export fn setTheta(theta: f64) void {
    if (std.math.isFinite(theta) and theta > 0) config.theta = theta;
}

export fn setTimeStep(time_step: f64) void {
    if (std.math.isFinite(time_step) and time_step > 0) config.time_step = time_step;
}

export fn setCameraLocked(locked: bool) void {
    lock_camera_to_center = locked;
    refreshParticles();
    refreshRegions();
}

export fn particlesPtr() usize {
    return @intFromPtr(&particles);
}

export fn particlesCount() u32 {
    return @intCast(particle_count);
}

export fn regionsPtr() usize {
    return @intFromPtr(&regions);
}

export fn regionsCount() u32 {
    return @intCast(region_count);
}

export fn stepCount() u32 {
    return steps;
}

export fn nodeCount() u32 {
    if (!ready) return 0;
    return @intCast(simulation.nodeCount() catch 0);
}

export fn bodyCount() u32 {
    return @intCast(if (ready) bodies.items.len else 0);
}

export fn rootLowX() f64 {
    return if (ready) simulation.tree.bounds().?.low[0] else 0;
}

export fn rootLowY() f64 {
    return if (ready) simulation.tree.bounds().?.low[1] else 0;
}

export fn rootHighX() f64 {
    return if (ready) simulation.tree.bounds().?.high[0] else 0;
}

export fn rootHighY() f64 {
    return if (ready) simulation.tree.bounds().?.high[1] else 0;
}
