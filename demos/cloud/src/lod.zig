const std = @import("std");
const fullaz = @import("fullaz");

const camera_mod = @import("camera.zig");
const constants = @import("constants.zig");
const point = @import("point.zig");
const trait_mod = @import("trait.zig");

const TraverseDecision = fullaz.spatial.orthtree.tree.TraverseDecision;

pub const Splat = struct {
    x: f64,
    y: f64,
    depth: f64,
    radius: f64,
    r: u8,
    g: u8,
    b: u8,
    // 1 for a real point, N for a node standing in for N of them.
    count: u32,
};

pub const Settings = struct {
    // A node covering less than this fraction of the viewport height is drawn
    // as one splat. Deliberately relative, not absolute: a terminal "pixel" is
    // a character cell, so the same number of pixels means something entirely
    // different in an 80x24 grid and in a 1200px canvas.
    detail_fraction: f64 = constants.default_detail_fraction,
    // Points have no extent, so give them a world size that shrinks with
    // distance like everything else.
    point_radius_world: f64 = constants.min_cell_extent * 4.0,
    min_radius_pixels: f64 = 0.5,
};

pub const Stats = struct {
    nodes_visited: usize = 0,
    nodes_accepted: usize = 0,
    nodes_empty: usize = 0,
    nodes_culled: usize = 0,

    // Every entry in the tree is accounted for exactly once by these three:
    //   accepted_points + culled_points + points_visited == entries in the tree
    // An aggregate covers its whole subtree because onInsert fires on every
    // node along the insertion path, and .accept returns before that node's
    // own entries are iterated.
    accepted_points: u64 = 0,
    culled_points: u64 = 0,
    points_visited: u64 = 0,

    splats_emitted: usize = 0,

    pub fn coveredPoints(self: Stats) u64 {
        return self.accepted_points + self.culled_points + self.points_visited;
    }
};

// Aggregates are deliberately not tinted like the points they stand for: a
// warm ramp on density reads as "this is a summary of many".
fn aggregateColour(count: u32) [3]u8 {
    const scale = std.math.clamp(@log2(@as(f64, @floatFromInt(count)) + 1.0) / 12.0, 0.0, 1.0);
    const warm: u8 = @intFromFloat(120.0 + 135.0 * scale);
    const cool: u8 = @intFromFloat(200.0 - 120.0 * scale);
    return .{ warm, @intCast(150 - @as(u16, cool) / 3), cool };
}

// One traversal, shared by both front ends; they differ only in `push`.
// Allocation-free by construction: the sink owns whatever storage it needs.
pub fn collect(
    tree: anytype,
    projector: *const camera_mod.Projector,
    settings: Settings,
    sink: anytype,
) !Stats {
    const Tree = @TypeOf(tree.*);
    const Box = Tree.Box;
    const Trait = Tree.Model.Trait;

    const Context = struct {
        projector: *const camera_mod.Projector,
        settings: Settings,
        threshold: f64,
        sink: @TypeOf(sink),
        stats: Stats = .{},

        fn onNode(
            self: *@This(),
            _: anytype,
            bounds: Box,
            node_trait: *const Trait,
            _: bool,
        ) !TraverseDecision {
            self.stats.nodes_visited += 1;

            // splitNode creates all eight children eagerly and most stay
            // empty, so this is load bearing rather than an optimisation: it
            // also keeps sum/count away from 0/0.
            const count = trait_mod.Splat.count(node_trait);
            if (count == 0) {
                self.stats.nodes_empty += 1;
                return .skip;
            }

            if (self.projector.cullsBox(bounds)) {
                self.stats.nodes_culled += 1;
                self.stats.culled_points += count;
                return .skip;
            }

            // Copy the aggregate out now: the pointer leads into a pinned page
            // frame that is released as soon as this returns.
            const centre = trait_mod.Splat.centroid(node_trait);
            const view = self.projector.toView(centre);
            const radius = point.boxRadius(bounds);

            const size = self.projector.pixelSize(radius, view[2]);
            // Never branch on is_leaf: entries live on internal nodes too, and
            // a camera inside the node has no meaningful projected size.
            if (!(size < self.threshold)) {
                return .descend;
            }

            const projected = self.projector.project(centre);
            if (!projected.visible) {
                return .descend;
            }

            const colour = aggregateColour(count);
            self.sink.push(.{
                .x = projected.x,
                .y = projected.y,
                .depth = projected.depth,
                .radius = @max(size * 0.5, self.settings.min_radius_pixels),
                .r = colour[0],
                .g = colour[1],
                .b = colour[2],
                .count = count,
            });
            self.stats.nodes_accepted += 1;
            self.stats.accepted_points += count;
            self.stats.splats_emitted += 1;
            return .accept;
        }

        fn onEntry(self: *@This(), bounds: Box, value: []const u8) !void {
            // Counted whether or not it ends up on screen, so the identity in
            // Stats stays exact.
            self.stats.points_visited += 1;

            const projected = self.projector.project(point.boxCenter(bounds));
            if (!projected.visible) return;

            // By value: the slice points into a pinned page.
            const record = point.PointRecord.fromBytes(value);
            const size = self.projector.pixelSize(
                self.settings.point_radius_world,
                projected.depth,
            );
            self.sink.push(.{
                .x = projected.x,
                .y = projected.y,
                .depth = projected.depth,
                .radius = @max(size * 0.5, self.settings.min_radius_pixels),
                .r = record.r,
                .g = record.g,
                .b = record.b,
                .count = 1,
            });
            self.stats.splats_emitted += 1;
        }
    };

    var context = Context{
        .projector = projector,
        .settings = settings,
        .threshold = settings.detail_fraction * projector.height,
        .sink = sink,
    };
    try tree.traverse(Context.onNode, Context.onEntry, &context);
    return context.stats;
}

// Discards everything; useful for measuring a traversal on its own.
pub const CountingSink = struct {
    pushes: usize = 0,

    pub fn push(self: *CountingSink, _: Splat) void {
        self.pushes += 1;
    }
};
