const std = @import("std");
const fullaz = @import("fullaz");
const constants = @import("constants.zig");

const PackedInt = fullaz.core.packed_int.PackedInt;
const PackedFloat = fullaz.core.packed_int.PackedFloat;

// The model does not propagate its Endian into the trait and nothing checks
// that they agree, so both sides read the same constant.
const U32 = PackedInt(u32, constants.endian);
// Coordinates are f32, the sum deliberately is not: over 200k points in a 65536
// cube it reaches ~1e10, where f32 carries ~1e3 of error and the centroid drifts
// far enough to see.
const F64 = PackedFloat(f64, constants.endian);

// Per-node aggregate: how many points live in the subtree and where their
// centre of mass is. That is all an LOD splat needs.
pub fn SplatTrait(comptime CoordT: type, comptime dims: usize, comptime ValueT: type) type {
    comptime {
        if (ValueT != []const u8) {
            @compileError("SplatTrait requires byte values");
        }
        if (@typeInfo(CoordT) != .float) {
            @compileError("SplatTrait requires float coordinates");
        }
    }

    return struct {
        pub const Storage = extern struct {
            count: U32,
            sum: [dims]F64,
        };
        pub const Error = error{};
        pub const Box = fullaz.spatial.BoundingBox(CoordT, dims);
        pub const Value = ValueT;

        pub fn format(storage: *Storage) void {
            storage.count.set(0);
            inline for (0..dims) |i| {
                storage.sum[i].set(0);
            }
        }

        // Runs on every loadNode, so it stays cheap. A page of garbage almost
        // always decodes to a non-finite double.
        pub fn validate(storage: *const Storage) bool {
            inline for (0..dims) |i| {
                if (!std.math.isFinite(storage.sum[i].get())) {
                    return false;
                }
            }
            return true;
        }

        pub fn onInsert(storage: *Storage, box: Box, _: Value) Error!void {
            accumulate(storage, box, 1);
        }

        pub fn onGrow(storage: *Storage, old: *const Storage) Error!void {
            storage.* = old.*;
        }

        pub fn onAdopt(storage: *Storage, box: Box, _: Value) Error!void {
            accumulate(storage, box, 1);
        }

        pub fn onRemove(storage: *Storage, box: Box, _: Value) Error!void {
            accumulate(storage, box, -1);
        }

        pub fn count(storage: *const Storage) u32 {
            return storage.count.get();
        }

        pub fn centroid(storage: *const Storage) [dims]f64 {
            var out: [dims]f64 = undefined;
            const total = storage.count.get();
            if (total == 0) {
                inline for (0..dims) |i| {
                    out[i] = 0;
                }
                return out;
            }
            const scale = 1.0 / @as(f64, @floatFromInt(total));
            inline for (0..dims) |i| {
                out[i] = storage.sum[i].get() * scale;
            }
            return out;
        }

        // Uses the box centre rather than its low corner: entries are point
        // boxes today, but nothing in the contract promises that.
        fn accumulate(storage: *Storage, box: Box, sign: i2) void {
            const delta: i64 = sign;
            storage.count.set(@intCast(@as(i64, storage.count.get()) + delta));
            inline for (0..dims) |i| {
                const low: f64 = @floatCast(box.low[i]);
                const high: f64 = @floatCast(box.high[i]);
                const mid = low + (high - low) * 0.5;
                storage.sum[i].set(storage.sum[i].get() + mid * @as(f64, @floatFromInt(delta)));
            }
        }
    };
}

// The instantiation the demo actually uses. Not named `Storage` at file scope:
// that would collide with the declaration inside SplatTrait itself.
pub const Splat = SplatTrait(constants.Coord, constants.dims, []const u8);

comptime {
    if (@alignOf(Splat.Storage) != 1) {
        @compileError("Orthtree paged trait storage must have alignment 1");
    }
}
