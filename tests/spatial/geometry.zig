const std = @import("std");
const fullaz = @import("fullaz");
const BoundingBox = fullaz.spatial.BoundingBox;

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

test "BoundingBox: containsBox checks full box containment" {
    const b = box(0, 0, 10, 10);

    try testing.expect(b.containsBox(&box(0, 0, 10, 10)));
    try testing.expect(b.containsBox(&box(2, 2, 8, 8)));
    try testing.expect(!b.containsBox(&box(-1, 2, 8, 8)));
    try testing.expect(!b.containsBox(&box(2, 2, 11, 8)));
    try testing.expect(!b.containsBox(&box(2, 2, 8, 11)));
}

test "BoundingBox: expanded grows all dimensions by amount" {
    const b = box(1, 2, 3, 4).expanded(2);

    try testing.expectEqual(box(-1, 0, 5, 6), b);
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

const FB = BoundingBox(f64, 2);

fn fbox(x0: f64, y0: f64, x1: f64, y1: f64) FB {
    return FB.initWith(.{ x0, y0 }, .{ x1, y1 });
}

test "BoundingBox: center of a float box is the true midpoint" {
    try testing.expectEqual(FB.Point{ 0.5, 0.5 }, fbox(0, 0, 1, 1).center());
    try testing.expectEqual(FB.Point{ 1.5, 1.5 }, fbox(0, 0, 3, 3).center());
    try testing.expectEqual(FB.Point{ 0, 0 }, fbox(-1, -1, 1, 1).center());
    try testing.expectEqual(FB.Point{ 5, 5 }, fbox(0, 0, 10, 10).center());
}

test "BoundingBox: center stays strictly inside a tiny float box" {
    const b = fbox(0, 0, 1e-6, 1e-6);
    const c = b.center();

    try testing.expectEqual(FB.Point{ 5e-7, 5e-7 }, c);
    // @divTrunc collapsed this onto `low`. Orthtree subdivision then produced a
    // child box identical to its parent and recursed to the depth limit.
    try testing.expect(c[0] > b.low[0] and c[0] < b.high[0]);
    try testing.expect(c[1] > b.low[1] and c[1] < b.high[1]);
}

test "BoundingBox: center of a float box below extent two still splits" {
    const b = fbox(0, 0, 1.5, 1.5);
    const c = b.center();

    try testing.expectEqual(FB.Point{ 0.75, 0.75 }, c);
    try testing.expect(c[0] > b.low[0] and c[0] < b.high[0]);
}

test "BoundingBox: center of an integer box still truncates toward low" {
    try testing.expectEqual(BB.Point{ 1, 1 }, box(0, 0, 3, 3).center());
    try testing.expectEqual(BB.Point{ -2, -2 }, box(-3, -3, 0, 0).center());
    try testing.expectEqual(BB.Point{ 0, 0 }, box(-1, -1, 1, 1).center());
}

test "BoundingBox: center of a large float box stays within the box" {
    const b = fbox(1e30, 1e30, 3e30, 3e30);
    const c = b.center();

    try testing.expectEqual(FB.Point{ 2e30, 2e30 }, c);
    try testing.expect(c[0] >= b.low[0] and c[0] <= b.high[0]);
}

test "spatial BoundingBox satisfies rtree key contract" {
    comptime fullaz.spatial.rtree.models.interfaces.assertKey(BB);
}
