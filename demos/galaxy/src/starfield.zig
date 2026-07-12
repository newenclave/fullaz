const std = @import("std");
const fullaz = @import("fullaz");
const constants = @import("constants.zig");

const PackedInt = fullaz.core.packed_int.PackedInt;
const E = constants.endian;

// One star, as stored in the R-tree value slot. The star's position is the
// R-tree key (a point box); this is the payload. Fixed extern layout, well
// under "max_value_size".
pub const Star = extern struct {
    id: PackedInt(u32, E),
    brightness: u8,
    class: u8,

    pub const size = @sizeOf(Star);

    pub fn bytes(self: *const Star) [size]u8 {
        return std.mem.toBytes(self.*);
    }

    pub fn fromBytes(b: []const u8) Star {
        return std.mem.bytesToValue(Star, b[0..size]);
    }
};

pub const StarSpec = struct {
    x: f64,
    y: f64,
    star: Star,
};

// Spectral classes, hottest → coolest, for a little flavor in the map legend.
pub const classes = "OBAFGKM";

pub fn cellSeed(cx: i64, cy: i64, world_seed: u64) u64 {
    var h = std.hash.Wyhash.init(world_seed);
    h.update(std.mem.asBytes(&cx));
    h.update(std.mem.asBytes(&cy));
    return h.final();
}

pub fn genCell(cx: i64, cy: i64, cell: f64, world_seed: u64, id_start: u32, out: []StarSpec) usize {
    var prng = std.Random.DefaultPrng.init(cellSeed(cx, cy, world_seed));
    const rnd = prng.random();

    if (rnd.float(f64) >= constants.star_density) return 0;

    const k: usize = 1 + @as(usize, @intCast(rnd.int(u64) % constants.star_jitter));

    const margin = cell * 0.02;
    const lo_x = @as(f64, @floatFromInt(cx)) * cell + margin;
    const lo_y = @as(f64, @floatFromInt(cy)) * cell + margin;
    const span = cell - 2 * margin;

    var i: usize = 0;
    while (i < k) : (i += 1) {
        out[i] = .{
            .x = lo_x + rnd.float(f64) * span,
            .y = lo_y + rnd.float(f64) * span,
            .star = .{
                .id = PackedInt(u32, E).init(id_start + @as(u32, @intCast(i))),
                .brightness = rnd.int(u8),
                .class = @intCast(rnd.uintLessThan(usize, classes.len)),
            },
        };
    }
    return k;
}

pub fn glyph(brightness: u8) u21 {
    return switch (brightness) {
        0...63 => '\u{00b7}', // ·
        64...127 => '+',
        128...191 => '*',
        else => '\u{2726}', // ✦
    };
}
