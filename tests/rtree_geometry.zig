const std = @import("std");
const fullaz = @import("fullaz");
const BoundingBox = fullaz.rtree.BoundingBox;

const testing = std.testing;

const BB = BoundingBox(i64, 2);

fn box(x0: i64, y0: i64, x1: i64, y1: i64) BB {
    return BB.initWith(.{ x0, y0 }, .{ x1, y1 });
}

test "BoundingBox: init is empty/zeroed and valid" {
    const b = BB.init();
    try testing.expect(b.valid());
    try testing.expectEqual(@as(i64, 0), b.measure());
}

test "BoundingBox: measure and perimeter" {
    const b = box(0, 0, 2, 3);
    try testing.expectEqual(@as(i64, 6), b.measure()); // 2 * 3
    try testing.expectEqual(@as(i64, 5), b.perimeter()); // 2 + 3
}

test "BoundingBox: merged is the union" {
    const m = box(0, 0, 2, 2).merged(&box(1, 1, 3, 3));
    try testing.expectEqual(box(0, 0, 3, 3), m);
    try testing.expectEqual(@as(i64, 9), m.measure());
}

test "BoundingBox: overlaps (half-open, touching does not overlap)" {
    try testing.expect(box(0, 0, 2, 2).overlaps(&box(1, 1, 3, 3)));
    try testing.expect(!box(0, 0, 1, 1).overlaps(&box(2, 2, 3, 3)));
    try testing.expect(!box(0, 0, 1, 1).overlaps(&box(1, 1, 2, 2))); // touching edges
}

test "BoundingBox: contains a point (half-open)" {
    const b = box(0, 0, 2, 2);
    try testing.expect(b.contains(.{ 1, 1 }));
    try testing.expect(!b.contains(.{ 2, 2 })); // high edge excluded
    try testing.expect(!b.contains(.{ 3, 3 }));
}

test "BoundingBox: enlargement = area added to include another box" {
    const a = box(0, 0, 2, 2); // area 4
    try testing.expectEqual(@as(i64, 5), a.enlargement(&box(1, 1, 3, 3))); // union area 9 - 4
    try testing.expectEqual(@as(i64, 0), a.enlargement(&box(0, 0, 1, 1))); // already contained
}

test "BoundingBox: overlapMeasure = area of the intersection (0 if disjoint)" {
    try testing.expectEqual(@as(i64, 1), box(0, 0, 2, 2).overlapMeasure(&box(1, 1, 3, 3)));
    try testing.expectEqual(@as(i64, 0), box(0, 0, 1, 1).overlapMeasure(&box(2, 2, 3, 3)));
    try testing.expectEqual(@as(i64, 0), box(0, 0, 1, 1).overlapMeasure(&box(1, 1, 2, 2))); // touching
}

test "BoundingBox: center" {
    try testing.expectEqual(BB.Point{ 1, 2 }, box(0, 0, 2, 4).center());
}

test "rtree contract: BoundingBox satisfies assertKey" {
    comptime fullaz.rtree.models.interfaces.assertKey(BB);
}
