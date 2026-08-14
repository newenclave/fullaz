const std = @import("std");
const common = @import("common.zig");

const cloud = common.cloud;
const trait = cloud.trait;
const Splat = trait.Splat;
const Storage = Splat.Storage;
const Box = cloud.Box;

const testing = std.testing;

fn point(x: f32, y: f32, z: f32) Box {
    return Box.create(.{ x, y, z }, .{ x, y, z });
}

fn formatted() Storage {
    var storage: Storage = undefined;
    Splat.format(&storage);
    return storage;
}

test "cloud: trait storage is twenty-eight bytes and byte aligned" {
    // 4 for the count plus three little-endian f64 sums.
    try testing.expectEqual(@as(usize, 28), @sizeOf(Storage));
    try testing.expectEqual(@as(usize, 1), @alignOf(Storage));
}

test "cloud: format zeroes the aggregate" {
    const storage = formatted();

    try testing.expectEqual(@as(u32, 0), Splat.count(&storage));
    try common.expectVecApprox(.{ 0, 0, 0 }, Splat.centroid(&storage), 1e-12);
    try testing.expect(Splat.validate(&storage));
}

test "cloud: inserts accumulate a count and a centroid" {
    var storage = formatted();

    try Splat.onInsert(&storage, point(0, 0, 0), "a");
    try Splat.onInsert(&storage, point(4, 8, 12), "b");
    try Splat.onInsert(&storage, point(2, 4, 6), "c");

    try testing.expectEqual(@as(u32, 3), Splat.count(&storage));
    try common.expectVecApprox(.{ 2, 4, 6 }, Splat.centroid(&storage), 1e-12);
}

test "cloud: adopting during a split accumulates like an insert" {
    var inserted = formatted();
    var adopted = formatted();

    try Splat.onInsert(&inserted, point(3, 5, 7), "a");
    try Splat.onAdopt(&adopted, point(3, 5, 7), "a");

    try testing.expectEqualSlices(u8, std.mem.asBytes(&inserted), std.mem.asBytes(&adopted));
}

test "cloud: removing reverses an insert exactly" {
    var storage = formatted();
    const empty = formatted();

    try Splat.onInsert(&storage, point(1.5, -2.25, 3.125), "a");
    try Splat.onRemove(&storage, point(1.5, -2.25, 3.125), "a");

    try testing.expectEqualSlices(u8, std.mem.asBytes(&empty), std.mem.asBytes(&storage));
}

test "cloud: growing the root carries the old aggregate over" {
    var old = formatted();
    try Splat.onInsert(&old, point(1, 2, 3), "a");
    try Splat.onInsert(&old, point(3, 4, 5), "b");

    var new_root = formatted();
    try Splat.onGrow(&new_root, &old);

    try testing.expectEqual(@as(u32, 2), Splat.count(&new_root));
    try common.expectVecApprox(.{ 2, 3, 4 }, Splat.centroid(&new_root), 1e-12);
}

test "cloud: the centroid of an empty node is not a division by zero" {
    const storage = formatted();
    const centre = Splat.centroid(&storage);

    inline for (0..cloud.constants.dims) |i| {
        try testing.expect(std.math.isFinite(centre[i]));
    }
}

test "cloud: validate rejects a non-finite sum" {
    var storage = formatted();
    try testing.expect(Splat.validate(&storage));

    storage.sum[1].set(std.math.nan(f64));
    try testing.expect(!Splat.validate(&storage));

    storage.sum[1].set(std.math.inf(f64));
    try testing.expect(!Splat.validate(&storage));
}

test "cloud: the aggregate uses the box centre, not its low corner" {
    var storage = formatted();
    try Splat.onInsert(&storage, Box.create(.{ 0, 0, 0 }, .{ 2, 4, 6 }), "a");

    try common.expectVecApprox(.{ 1, 2, 3 }, Splat.centroid(&storage), 1e-12);
}
