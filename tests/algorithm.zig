const algorithm = @import("fullaz").algorithm;
const std = @import("std");
const expect = std.testing.expect;

test "Algorithm cmpNum function" {
    const a = 10;
    const b = 20;
    try expect(algorithm.cmpNum(void, a, b) == .lt);
    try expect(algorithm.cmpNum(void, b, a) == .gt);
    try expect(algorithm.cmpNum(void, a, a) == .eq);
}

test "Algorithm cmpNum function floats" {
    const a = 10.10;
    const b = 20.20;
    const nan = std.math.nan(@TypeOf(a));
    try expect(algorithm.cmpNum(void, a, b) == .lt);
    try expect(algorithm.cmpNum(void, b, a) == .gt);
    try expect(algorithm.cmpNum(void, a, a) == .eq);
    try expect(algorithm.cmpNum(void, nan, a) == .unordered);
    try expect(algorithm.cmpNum(void, a, nan) == .unordered);
    try expect(algorithm.cmpNum(void, nan, nan) == .eq);
}

test "Algorithm cmpSlices function" {
    const slice1 = [_]u8{ 1, 2, 3, 4 };
    const slice2 = [_]u8{ 1, 2, 3, 5 };
    const slice3 = [_]u8{ 1, 2, 3, 4 };

    try expect(try algorithm.cmpSlices(u8, slice1[0..], slice2[0..], algorithm.CmpNum(u8).asc, void) == .lt);
    try expect(try algorithm.cmpSlices(u8, slice2[0..], slice1[0..], algorithm.CmpNum(u8).asc, void) == .gt);
    try expect(try algorithm.cmpSlices(u8, slice1[0..], slice3[0..], algorithm.CmpNum(u8).asc, void) == .eq);
}

test "Algorithm cmpSlices function floats" {
    const slice1 = [_]f32{ 1, 2, 3, 4 };
    const slice2 = [_]f32{ 1, 2, 3, 5 };
    const slice3 = [_]f32{ 1, 2, 3, 4 };
    const slicenan = [_]f32{ std.math.nan(f32), 2, 3, 4 };

    const cmp = algorithm.CmpNum(f32).asc;

    try expect(try algorithm.cmpSlices(f32, slice1[0..], slice2[0..], cmp, void) == .lt);
    try expect(try algorithm.cmpSlices(f32, slice2[0..], slice1[0..], cmp, void) == .gt);
    try expect(try algorithm.cmpSlices(f32, slice1[0..], slice3[0..], cmp, void) == .eq);
    try expect(try algorithm.cmpSlices(f32, slice1[0..], slice3[0..], cmp, void) == .eq);
    try expect(try algorithm.cmpSlices(f32, slicenan[0..], slice1[0..], cmp, void) == .unordered);
    try expect(try algorithm.cmpSlices(f32, slice1[0..], slicenan[0..], cmp, void) == .unordered);
    try expect(try algorithm.cmpSlices(f32, slicenan[0..], slicenan[0..], cmp, void) == .eq);
}
