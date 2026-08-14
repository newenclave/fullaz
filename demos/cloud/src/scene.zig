const std = @import("std");
const constants = @import("constants.zig");
const point = @import("point.zig");

const Vec3 = point.Vec3;
const Coord = constants.Coord;

pub const max_clusters: u16 = 24;
pub const background_cluster: u8 = 0xFF;

// Cluster cores sit far enough from the walls that a sample essentially never
// needs clamping: the margin is about five sigma of the widest cluster.
const cluster_margin: f64 = 12000.0;
const sigma_min: f64 = 400.0;
const sigma_max: f64 = 2500.0;
const wall_margin: f64 = 1.0;

// Not a Spec field on purpose: the superblock persists seed and cluster count,
// so anything else that steers generation would silently change on reopen.
pub const background_fraction: f64 = 0.15;

pub const Spec = struct {
    seed: u64,
    cluster_count: u16 = 12,
};

pub const Cluster = struct {
    center: Vec3,
    sigma: f64,
    color: [3]u8,
};

pub const Sample = struct {
    position: Vec3,
    record: point.PointRecord,
};

// splitmix64. Reseeding per sample is what makes sampleAt a pure function of
// the index, so generation resumes after a reopen from next_point_id alone.
fn mix(seed: u64, index: u64) u64 {
    var z = seed +% (index +% 1) *% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

fn prngFor(seed: u64, index: u64) std.Random.DefaultPrng {
    return std.Random.DefaultPrng.init(mix(seed, index));
}

// Box-Muller. floatMin keeps @log away from zero, which would give -inf.
fn gaussian(random: std.Random) f64 {
    const u = @max(random.float(f64), std.math.floatMin(f64));
    const v = random.float(f64);
    return @sqrt(-2.0 * @log(u)) * @cos(2.0 * std.math.pi * v);
}

fn insideCube(value: f64) Coord {
    return @floatCast(std.math.clamp(
        value,
        wall_margin,
        @as(f64, constants.root_side) - wall_margin,
    ));
}

pub fn clusterAt(spec: Spec, index: u16) Cluster {
    var prng = prngFor(spec.seed ^ 0xC1057E12, index);
    const random = prng.random();

    var center: Vec3 = undefined;
    inline for (0..constants.dims) |axis| {
        const span = @as(f64, constants.root_side) - 2.0 * cluster_margin;
        center[axis] = insideCube(cluster_margin + random.float(f64) * span);
    }

    return .{
        .center = center,
        .sigma = sigma_min + random.float(f64) * (sigma_max - sigma_min),
        .color = .{
            120 + random.uintLessThan(u8, 136),
            120 + random.uintLessThan(u8, 136),
            120 + random.uintLessThan(u8, 136),
        },
    };
}

pub fn sampleAt(spec: Spec, index: u32) Sample {
    var prng = prngFor(spec.seed, index);
    const random = prng.random();

    const clusters = @min(@max(spec.cluster_count, 1), max_clusters);
    const in_background = random.float(f64) < background_fraction;

    var position: Vec3 = undefined;
    var color: [3]u8 = undefined;
    var cluster_id: u8 = background_cluster;

    if (in_background) {
        inline for (0..constants.dims) |axis| {
            position[axis] = insideCube(random.float(f64) * @as(f64, constants.root_side));
        }
        // Dim grey so the structure of the clusters stays readable.
        const shade = 70 + random.uintLessThan(u8, 40);
        color = .{ shade, shade, shade + 20 };
    } else {
        const which = random.uintLessThan(u16, clusters);
        const cluster = clusterAt(spec, which);
        inline for (0..constants.dims) |axis| {
            const offset = gaussian(random) * cluster.sigma;
            position[axis] = insideCube(@as(f64, cluster.center[axis]) + offset);
        }
        color = cluster.color;
        cluster_id = @intCast(which);
    }

    return .{
        .position = position,
        .record = .{
            .id = .init(index),
            .r = color[0],
            .g = color[1],
            .b = color[2],
            .cluster = cluster_id,
        },
    };
}
