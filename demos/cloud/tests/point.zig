const std = @import("std");
const common = @import("common.zig");

const cloud = common.cloud;
const point = cloud.point;

const testing = std.testing;

test "cloud: point record is eight bytes and byte aligned" {
    try testing.expectEqual(@as(usize, 8), point.record_size);
    try testing.expectEqual(@as(usize, 1), @alignOf(point.PointRecord));
}

test "cloud: point record round-trips through bytes" {
    const original = point.PointRecord{
        .id = .init(0xDEADBEEF),
        .r = 255,
        .g = 0,
        .b = 128,
        .cluster = 7,
    };

    const encoded = original.bytes();
    const decoded = point.PointRecord.fromBytes(&encoded);

    try testing.expectEqual(@as(u32, 0xDEADBEEF), decoded.id.get());
    try testing.expectEqual(@as(u8, 255), decoded.r);
    try testing.expectEqual(@as(u8, 0), decoded.g);
    try testing.expectEqual(@as(u8, 128), decoded.b);
    try testing.expectEqual(@as(u8, 7), decoded.cluster);
}

test "cloud: box helpers describe a cube" {
    const b = cloud.Box.create(.{ 0, 0, 0 }, .{ 2, 2, 2 });

    try common.expectVecApprox(.{ 1, 1, 1 }, point.boxCenter(b), 1e-12);
    // Half the diagonal of a 2-unit cube: sqrt(3).
    try testing.expectApproxEqAbs(@sqrt(3.0), point.boxRadius(b), 1e-12);
}

test "cloud: a point box is degenerate and centred on the point" {
    const p: cloud.Vec3 = .{ 1.5, -2.25, 3.125 };
    const b = point.boxFor(p);

    try testing.expectEqual(p, b.low);
    try testing.expectEqual(p, b.high);
    try testing.expectApproxEqAbs(@as(f64, 0), point.boxRadius(b), 1e-12);
    try common.expectVecApprox(point.widen(p), point.boxCenter(b), 1e-12);
}

test "cloud: the root cube is a power of two anchored at the origin" {
    const root = cloud.constants.rootBox();

    try testing.expectEqual(@as(cloud.Coord, 0), root.low[0]);
    try testing.expectEqual(cloud.constants.root_side, root.high[0]);
    // Subdivision must reach min_cell_extent in exactly max_tree_depth steps.
    try testing.expectEqual(
        cloud.constants.min_cell_extent,
        cloud.constants.root_side / @as(cloud.Coord, @floatFromInt(@as(u64, 1) << cloud.constants.max_tree_depth)),
    );
}
