const std = @import("std");
const fullaz = @import("fullaz");
const BoundingBox = fullaz.spatial.BoundingBox;

const testing = std.testing;

const BB = BoundingBox(i64, 2);
const FB = BoundingBox(f64, 2);
const BB4 = BoundingBox(i64, 4);

fn box(x0: i64, y0: i64, x1: i64, y1: i64) BB {
    return BB.initWith(.{ x0, y0 }, .{ x1, y1 });
}

test "BoundingBox: init is empty/zeroed and valid" {
    const b = BB.init();
    try testing.expect(b.valid());
    try testing.expectEqual(@as(i64, 0), b.measure());
}

test "BoundingBox: init is empty/zeroed f64 and valid" {
    const b = FB.init();
    try testing.expect(b.valid());
    try testing.expectEqual(@as(f64, 0), b.measure());
}

test "BoundingBox: measure and perimeter" {
    const b = box(0, 0, 2, 3);
    try testing.expectEqual(@as(i64, 6), b.measure()); // 2 * 3
    try testing.expectEqual(@as(i64, 5), b.perimeter()); // 2 + 3
}

test "BoundingBox: range metrics use selected coordinates" {
    const b = BB4.initWith(.{ 0, 0, 0, 0 }, .{ 2, 3, 5, 7 });
    const changed_u = BB4.initWith(.{ 0, 0, 0, 0 }, .{ 2, 3, 5, 100 });

    try testing.expectEqual(b.measure(), b.measureN(0, 4));
    try testing.expectEqual(b.perimeter(), b.perimeterN(0, 4));
    try testing.expectEqual(b.surfaceArea(), b.surfaceAreaN(0, 4));
    try testing.expectEqual(@as(i64, 210), b.measure());
    try testing.expectEqual(@as(i64, 17), b.perimeter());
    try testing.expectEqual(@as(i64, 494), b.surfaceArea());
    try testing.expectEqual(@as(i64, 30), b.measureN(0, 3));
    try testing.expectEqual(@as(i64, 10), b.perimeterN(0, 3));
    try testing.expectEqual(@as(i64, 62), b.surfaceAreaN(0, 3));
    try testing.expectEqual(@as(i64, 15), b.measureN(1, 2));
    try testing.expectEqual(@as(i64, 8), b.perimeterN(1, 2));
    try testing.expectEqual(@as(i64, 16), b.surfaceAreaN(1, 2));

    try testing.expectEqual(b.measureN(0, 3), changed_u.measureN(0, 3));
    try testing.expectEqual(b.perimeterN(0, 3), changed_u.perimeterN(0, 3));
    try testing.expectEqual(b.surfaceAreaN(0, 3), changed_u.surfaceAreaN(0, 3));
}

test "BoundingBox: sliceN and embed transform coordinate dimensions" {
    const b = BB4.initWith(.{ 0, 0, 0, 0 }, .{ 1, 2, 3, 4 });
    const slice = b.sliceN(1, 2);
    const embedded = BB4.embed(&slice, 1);

    try testing.expectEqual(BoundingBox(i64, 2).initWith(.{ 0, 0 }, .{ 2, 3 }), slice);
    try testing.expectEqual(BB4.initWith(.{ 0, 0, 0, 0 }, .{ 0, 2, 3, 0 }), embedded);
}

test "BoundingBox: partial metrics preserve full-dimensional geometry" {
    const flat_u = BB4.initWith(.{ 0, 0, 0, 42 }, .{ 10, 20, 30, 42 });
    const larger_flat_u = BB4.initWith(.{ 0, 0, 0, 42 }, .{ 20, 20, 30, 42 });
    const touching_u = BB4.initWith(.{ 5, 5, 5, 42 }, .{ 15, 15, 15, 42 });
    const a = BB4.initWith(.{ 0, 0, 0, 0 }, .{ 2, 2, 2, 1 });
    const disjoint_u = BB4.initWith(.{ 0, 0, 0, 1 }, .{ 2, 2, 2, 2 });
    const outside_u = BB4.initWith(.{ 0, 0, 0, 1 }, .{ 1, 1, 1, 2 });

    try testing.expectEqual(@as(i64, 0), flat_u.measure());
    try testing.expectEqual(@as(i64, 0), flat_u.measureN(0, 4));
    try testing.expectEqual(@as(i64, 6_000), flat_u.measureN(0, 3));
    try testing.expectEqual(@as(i64, 0), flat_u.enlargement(&larger_flat_u));
    try testing.expectEqual(@as(i64, 6_000), flat_u.enlargementN(&larger_flat_u, 0, 3));
    try testing.expectEqual(@as(i64, 0), flat_u.overlapMeasure(&touching_u));
    try testing.expectEqual(@as(i64, 500), flat_u.overlapMeasureN(&touching_u, 0, 3));
    try testing.expect(flat_u.intersects(&touching_u));
    try testing.expect(!flat_u.overlaps(&touching_u));
    try testing.expect(!a.overlaps(&disjoint_u));
    try testing.expect(!a.containsBox(&outside_u));
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

test "BoundingBox: intersects includes touching boundaries" {
    const a = box(0, 0, 1, 1);
    const touching = box(1, 0, 2, 1);
    const disjoint = box(2, 0, 3, 1);

    try testing.expect(a.intersects(&touching));
    try testing.expect(!a.overlaps(&touching));
    try testing.expect(!a.intersects(&disjoint));
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

test "BoundingBox: splittable rejects a box whose center does not separate" {
    // An integer extent of 1 puts center() on `low`, so childBounds would hand
    // back a child identical to the parent and subdivision would never progress.
    try testing.expect(!box(0, 0, 1, 1).splittable(0));
    try testing.expect(box(0, 0, 2, 2).splittable(0));
    try testing.expect(box(0, 0, 3, 3).splittable(0));
    // One degenerate axis is enough to refuse.
    try testing.expect(!box(0, 0, 4, 0).splittable(0));
}

test "BoundingBox: splittable honours a minimum cell extent" {
    try testing.expect(box(0, 0, 8, 8).splittable(4)); // children are 4x4
    try testing.expect(!box(0, 0, 8, 8).splittable(5));
    try testing.expect(!box(0, 0, 4, 4).splittable(4)); // children would be 2x2
    try testing.expect(box(0, 0, 4, 4).splittable(2));
}

test "BoundingBox: splittable keeps float boxes below extent two usable" {
    try testing.expect(fbox(0, 0, 1.5, 1.5).splittable(0));
    try testing.expect(fbox(0, 0, 1e-6, 1e-6).splittable(0));
    try testing.expect(!fbox(0, 0, 1e-6, 1e-6).splittable(1e-3));
}

test "BoundingBox: splittable refuses non-finite float bounds" {
    const nan = std.math.nan(f64);

    try testing.expect(!fbox(0, 0, nan, nan).splittable(0));
    try testing.expect(!fbox(nan, nan, 1, 1).splittable(0));
}

test "spatial BoundingBox satisfies rtree key contract" {
    comptime fullaz.spatial.rtree.models.interfaces.assertKey(BB);
}
