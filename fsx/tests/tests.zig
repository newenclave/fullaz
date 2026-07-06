const std = @import("std");
const fullaz = @import("fullaz");
const zigline = @import("zigline");

test "fsx scaffold: fullaz and zigline modules import" {
    _ = fullaz;
    _ = zigline;
}
