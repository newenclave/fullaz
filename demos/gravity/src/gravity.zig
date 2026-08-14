const std = @import("std");
const fullaz = @import("fullaz");

const orthtree = fullaz.spatial.orthtree;

pub const Point = [2]f64;

pub const Body = struct {
    position: Point,
    velocity: Point = .{ 0, 0 },
    mass: f64 = 0,
    id: usize = std.math.maxInt(usize),
};

pub const Config = struct {
    gravitational_constant: f64 = 1,
    theta: f64 = 0.5,
    softening: f64 = 0.1,
    time_step: f64 = 0.01,
};

pub const GalaxyOptions = struct {
    body_count: usize = 300,
    seed: u64 = 42,
    central_mass: f64 = 100_000_000.0,
};

pub const MassData = struct {
    body_count: usize = 0,
    total_mass: f64 = 0,
    weighted_position_sum: Point = .{ 0, 0 },
};

pub fn MassTrait(comptime Coord: type, comptime dimension: usize, comptime Value: type) type {
    comptime {
        if (Coord != f64 or dimension != 2 or Value != Body) {
            @compileError("MassTrait requires f64, two dimensions, and Body values");
        }
    }

    return struct {
        const Self = @This();
        pub const Error = error{};

        data: MassData = .{},

        pub fn init() Self {
            return .{};
        }

        pub fn onInsert(self: *Self, _: anytype, body: Body) Error!void {
            self.add(body);
        }

        pub fn onGrow(self: *Self, old: *const Self) Error!void {
            self.data = old.data;
        }

        pub fn onAdopt(self: *Self, _: anytype, body: Body) Error!void {
            self.add(body);
        }

        pub fn onRemove(self: *Self, _: anytype, body: Body) Error!void {
            self.data.body_count -= 1;
            self.data.total_mass -= body.mass;
            self.data.weighted_position_sum[0] -= body.position[0] * body.mass;
            self.data.weighted_position_sum[1] -= body.position[1] * body.mass;
        }

        fn add(self: *Self, body: Body) void {
            self.data.body_count += 1;
            self.data.total_mass += body.mass;
            self.data.weighted_position_sum[0] += body.position[0] * body.mass;
            self.data.weighted_position_sum[1] += body.position[1] * body.mass;
        }
    };
}

pub const Model = orthtree.models.MemoryImpl(f64, 2, Body, MassTrait);
pub const Tree = orthtree.tree.TreeImpl(Model);
pub const Box = Model.Box;
pub const Trait = Model.Trait;

pub fn centerOfMass(data: MassData) Point {
    if (data.total_mass == 0) return .{ 0, 0 };
    return .{
        data.weighted_position_sum[0] / data.total_mass,
        data.weighted_position_sum[1] / data.total_mass,
    };
}

pub fn bodyBounds(body: Body) Box {
    return Box.create(body.position, body.position);
}

pub fn makeGalaxy(allocator: std.mem.Allocator, options: GalaxyOptions) !std.ArrayList(Body) {
    var bodies = try std.ArrayList(Body).initCapacity(allocator, options.body_count + 1);
    errdefer bodies.deinit(allocator);

    try bodies.append(allocator, .{
        .position = .{ 0, 0 },
        .mass = options.central_mass,
        .id = 0,
    });

    var prng = std.Random.DefaultPrng.init(options.seed);
    const random = prng.random();
    for (0..options.body_count) |index| {
        const angle = random.float(f64) * 2.0 * std.math.pi;
        const radius = 12.0 + @sqrt(random.float(f64)) * 88.0;
        const velocity_factor = 0.92 + random.float(f64) * 0.16;
        // A deliberately top-heavy tail makes the browser scene show a useful
        // mix of red dwarfs, sun-like stars, blue giants, and rare supergiants.
        const mass_roll = random.float(f64);
        const mass = if (mass_roll < 0.70)
            0.15 + random.float(f64) * 0.65
        else if (mass_roll < 0.90)
            0.80 + random.float(f64) * 0.60
        else if (mass_roll < 0.99)
            1.40 + random.float(f64) * 3.60
        else
            8.0 + random.float(f64) * 12.0;
        const speed = @sqrt(options.central_mass / radius) * velocity_factor;
        try bodies.append(allocator, .{
            .position = .{ @cos(angle) * radius, @sin(angle) * radius },
            .velocity = .{ -@sin(angle) * speed, @cos(angle) * speed },
            .mass = mass,
            .id = index + 1,
        });
    }
    return bodies;
}

pub fn accelerationFromMass(target: Body, source_position: Point, source_mass: f64, config: Config) Point {
    const dx = source_position[0] - target.position[0];
    const dy = source_position[1] - target.position[1];
    const distance_squared = dx * dx + dy * dy;
    const softened_distance_squared = distance_squared + config.softening * config.softening;
    if (source_mass == 0 or softened_distance_squared == 0) return .{ 0, 0 };

    const inverse_distance = 1.0 / @sqrt(softened_distance_squared);
    const scale = config.gravitational_constant * source_mass *
        inverse_distance * inverse_distance * inverse_distance;
    return .{ dx * scale, dy * scale };
}

pub fn directAcceleration(bodies: []const Body, target: Body, config: Config) Point {
    var result: Point = .{ 0, 0 };
    for (bodies) |source| {
        if (source.id == target.id) continue;
        const acceleration = accelerationFromMass(
            target,
            source.position,
            source.mass,
            config,
        );
        result[0] += acceleration[0];
        result[1] += acceleration[1];
    }
    return result;
}

pub fn barnesHutAcceleration(tree: *const Tree, target: Body, config: Config) !Point {
    const Context = struct {
        target: Body,
        config: Config,
        acceleration: Point = .{ 0, 0 },

        fn onNode(ctx: *@This(), _: usize, bounds: Box, trait: *const Trait, _: bool) !orthtree.tree.TraverseDecision {
            const data = trait.data;
            if (data.total_mass == 0) return .descend;

            const center = centerOfMass(data);
            const dx = center[0] - ctx.target.position[0];
            const dy = center[1] - ctx.target.position[1];
            const distance = @sqrt(dx * dx + dy * dy);
            const width = @max(bounds.high[0] - bounds.low[0], bounds.high[1] - bounds.low[1]);
            const target_bounds = bodyBounds(ctx.target);

            if (!bounds.containsBox(&target_bounds) and distance != 0 and width / distance < ctx.config.theta) {
                const acceleration = accelerationFromMass(
                    ctx.target,
                    center,
                    data.total_mass,
                    ctx.config,
                );
                ctx.acceleration[0] += acceleration[0];
                ctx.acceleration[1] += acceleration[1];
                return .accept;
            }
            return .descend;
        }

        fn onEntry(ctx: *@This(), _: Box, body: Body) !void {
            if (body.id == ctx.target.id) return;
            const acceleration = accelerationFromMass(
                ctx.target,
                body.position,
                body.mass,
                ctx.config,
            );
            ctx.acceleration[0] += acceleration[0];
            ctx.acceleration[1] += acceleration[1];
        }
    };

    var context = Context{ .target = target, .config = config };
    try tree.traverse(Context.onNode, Context.onEntry, &context);
    return context.acceleration;
}

pub const Simulation = struct {
    const Self = @This();
    pub const initial_bounds = Box.create(.{ -128, -128 }, .{ 128, 128 });
    pub const max_leaf_entries = 4;
    // Below the softening length the force law is smoothed, so cells finer than
    // that separate nothing the simulation can feel. Without a floor the dense
    // galactic core keeps subdividing until the depth limit stops it.
    pub const min_cell_extent: f64 = (Config{}).softening;

    fn modelSettings() Model.Settings {
        return .{
            .max_leaf_entries = max_leaf_entries,
            .min_cell_extent = min_cell_extent,
        };
    }

    allocator: std.mem.Allocator,
    model: *Model,
    tree: Tree,

    pub fn init(allocator: std.mem.Allocator, bodies: []const Body) !Self {
        const model = try allocator.create(Model);
        errdefer allocator.destroy(model);
        model.* = try Model.initWithSettings(allocator, Trait.init(), modelSettings());
        errdefer model.deinit();

        var self = Self{
            .allocator = allocator,
            .model = model,
            .tree = Tree.init(model),
        };
        try self.populate(bodies);
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.model.deinit();
        self.allocator.destroy(self.model);
    }

    pub fn rebuild(self: *Self, bodies: []const Body) !void {
        const new_model = try self.allocator.create(Model);
        errdefer self.allocator.destroy(new_model);
        new_model.* = try Model.initWithSettings(self.allocator, Trait.init(), modelSettings());
        errdefer new_model.deinit();

        var new_tree = Tree.init(new_model);
        try new_tree.initRootBounds(try boundsForBodies(bodies));
        for (bodies) |body| try new_tree.insert(bodyBounds(body), body);

        const old_model = self.model;
        self.model = new_model;
        self.tree = Tree.init(new_model);
        old_model.deinit();
        self.allocator.destroy(old_model);
    }

    pub fn advance(self: *Self, bodies: []Body, config: Config) !void {
        var accelerations = try std.ArrayList(Point).initCapacity(self.allocator, bodies.len);
        defer accelerations.deinit(self.allocator);

        for (bodies) |body| {
            try accelerations.append(self.allocator, try barnesHutAcceleration(&self.tree, body, config));
        }
        for (bodies, accelerations.items) |*body, acceleration| {
            body.velocity[0] += acceleration[0] * config.time_step;
            body.velocity[1] += acceleration[1] * config.time_step;
            body.position[0] += body.velocity[0] * config.time_step;
            body.position[1] += body.velocity[1] * config.time_step;
        }
        try self.rebuild(bodies);
    }

    pub fn nodeCount(self: *Self) !usize {
        const Counter = struct {
            count: usize = 0,

            fn visit(ctx: *@This(), _: usize, _: Box, _: *Trait) !orthtree.tree.VisitorResult {
                ctx.count += 1;
                return .descend;
            }
        };
        var counter = Counter{};
        try self.tree.visitNodes(Counter.visit, &counter);
        return counter.count;
    }

    fn populate(self: *Self, bodies: []const Body) !void {
        try self.tree.initRootBounds(try boundsForBodies(bodies));
        for (bodies) |body| try self.tree.insert(bodyBounds(body), body);
    }

    fn boundsForBodies(bodies: []const Body) !Box {
        if (bodies.len == 0) return initial_bounds;

        var low = bodies[0].position;
        var high = low;
        inline for (0..2) |axis| {
            if (!std.math.isFinite(low[axis])) return error.InvalidId;
        }
        for (bodies[1..]) |body| {
            inline for (0..2) |axis| {
                if (!std.math.isFinite(body.position[axis])) return error.InvalidId;
                low[axis] = @min(low[axis], body.position[axis]);
                high[axis] = @max(high[axis], body.position[axis]);
            }
        }

        const span = @max(@max(high[0] - low[0], high[1] - low[1]), 20.0);
        const padding = span * 0.1;
        const center: Point = .{ (low[0] + high[0]) / 2, (low[1] + high[1]) / 2 };
        return Box.create(
            .{ center[0] - span / 2 - padding, center[1] - span / 2 - padding },
            .{ center[0] + span / 2 + padding, center[1] + span / 2 + padding },
        );
    }
};
