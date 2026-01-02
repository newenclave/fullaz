const algorithm = @import("fullaz").algorithm;
const std = @import("std");
const expect = std.testing.expect;

test "Algorithm cmpNum function" {
    const a = 10;
    const b = 20;
    try expect(algorithm.cmpNum(a, b) == .lt);
    try expect(algorithm.cmpNum(b, a) == .gt);
    try expect(algorithm.cmpNum(a, a) == .eq);
}

test "Algorithm cmpNum function floats" {
    const a = 10.10;
    const b = 20.20;
    const nan = std.math.nan(@TypeOf(a));
    try expect(algorithm.cmpNum(a, b) == .lt);
    try expect(algorithm.cmpNum(b, a) == .gt);
    try expect(algorithm.cmpNum(a, a) == .eq);
    try expect(algorithm.cmpNum(nan, a) == .unordered);
    try expect(algorithm.cmpNum(a, nan) == .unordered);
    try expect(algorithm.cmpNum(nan, nan) == .eq);
}

test "Algorithm cmpSlices function" {
    const slice1 = [_]u8{ 1, 2, 3, 4 };
    const slice2 = [_]u8{ 1, 2, 3, 5 };
    const slice3 = [_]u8{ 1, 2, 3, 4 };

    try expect(algorithm.cmpSlices(u8, slice1[0..], slice2[0..], algorithm.CmpNum(u8).asc) == .lt);
    try expect(algorithm.cmpSlices(u8, slice2[0..], slice1[0..], algorithm.CmpNum(u8).asc) == .gt);
    try expect(algorithm.cmpSlices(u8, slice1[0..], slice3[0..], algorithm.CmpNum(u8).asc) == .eq);
}

test "Algorithm cmpSlices function floats" {
    const slice1 = [_]f32{ 1, 2, 3, 4 };
    const slice2 = [_]f32{ 1, 2, 3, 5 };
    const slice3 = [_]f32{ 1, 2, 3, 4 };
    const slicenan = [_]f32{ std.math.nan(f32), 2, 3, 4 };

    const cmp = algorithm.CmpNum(f32).asc;

    try expect(algorithm.cmpSlices(f32, slice1[0..], slice2[0..], cmp) == .lt);
    try expect(algorithm.cmpSlices(f32, slice2[0..], slice1[0..], cmp) == .gt);
    try expect(algorithm.cmpSlices(f32, slice1[0..], slice3[0..], cmp) == .eq);
    try expect(algorithm.cmpSlices(f32, slice1[0..], slice3[0..], cmp) == .eq);
    try expect(algorithm.cmpSlices(f32, slicenan[0..], slice1[0..], cmp) == .unordered);
    try expect(algorithm.cmpSlices(f32, slice1[0..], slicenan[0..], cmp) == .unordered);
    try expect(algorithm.cmpSlices(f32, slicenan[0..], slicenan[0..], cmp) == .eq);
}
