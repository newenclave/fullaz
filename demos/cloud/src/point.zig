const std = @import("std");
const fullaz = @import("fullaz");
const constants = @import("constants.zig");

const PackedInt = fullaz.core.packed_int.PackedInt;

pub const Box = constants.Box;
// Tree coordinates are f32; camera and LOD math widen to f64.
pub const Vec3 = constants.Vec3;
pub const Vec3d = [constants.dims]f64;

pub const record_size = @sizeOf(PointRecord);

// The position is the tree key, so it is deliberately not repeated here: both
// onInsert and on_entry hand it back as a degenerate box.
pub const PointRecord = extern struct {
    id: PackedInt(u32, constants.endian),
    r: u8,
    g: u8,
    b: u8,
    cluster: u8,

    pub fn bytes(self: *const PointRecord) [record_size]u8 {
        return std.mem.toBytes(self.*);
    }

    pub fn fromBytes(data: []const u8) PointRecord {
        return std.mem.bytesToValue(PointRecord, data[0..record_size]);
    }
};

comptime {
    if (@alignOf(PointRecord) != 1) {
        @compileError("PointRecord must be byte aligned to survive the page round-trip");
    }
}

pub fn boxFor(p: Vec3) Box {
    return Box.create(p, p);
}

pub fn widen(p: Vec3) Vec3d {
    var out: Vec3d = undefined;
    inline for (0..constants.dims) |i| {
        out[i] = @floatCast(p[i]);
    }
    return out;
}

pub fn boxCenter(b: Box) Vec3d {
    var out: Vec3d = undefined;
    inline for (0..constants.dims) |i| {
        const low: f64 = @floatCast(b.low[i]);
        const high: f64 = @floatCast(b.high[i]);
        out[i] = low + (high - low) * 0.5;
    }
    return out;
}

// Radius of the bounding sphere, i.e. half the diagonal. The LOD test needs
// this rather than an edge length: an edge understates a cube's screen size by
// sqrt(3) and would prune far too eagerly.
pub fn boxRadius(b: Box) f64 {
    var sum: f64 = 0;
    inline for (0..constants.dims) |i| {
        const extent: f64 = @floatCast(b.high[i] - b.low[i]);
        sum += extent * extent;
    }
    return @sqrt(sum) * 0.5;
}
