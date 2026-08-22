const std = @import("std");
const fullaz = @import("fullaz");

const size_classes = fullaz.storage.fsm.size_classes;

test "Fsm size classes: one maps all sizes to its only class" {
    const policy = size_classes.One{};

    try std.testing.expectEqual(@as(u16, 0), policy.getSizeClass(0));
    try std.testing.expectEqual(@as(u16, 0), policy.getSizeClass(std.math.maxInt(u16)));
    try std.testing.expectEqual(@as(usize, 1), policy.count());
}

test "Fsm size classes: logarithmic policy maps by rounded-up powers" {
    const policy = try size_classes.Logarithmic.init(.{
        .minimum_tracked_space = 8,
    });

    try std.testing.expectEqual(@as(u16, 0), policy.getSizeClass(0));
    try std.testing.expectEqual(@as(u16, 0), policy.getSizeClass(8));
    try std.testing.expectEqual(@as(u16, 1), policy.getSizeClass(9));
    try std.testing.expectEqual(@as(u16, 1), policy.getSizeClass(64));
    try std.testing.expectEqual(@as(u16, 2), policy.getSizeClass(65));
    try std.testing.expectEqual(@as(usize, 6), policy.count());
}

test "Fsm size classes: logarithmic policy rejects invalid options" {
    try std.testing.expectError(error.InvalidBase, size_classes.Logarithmic.init(.{
        .base = 1,
    }));
    try std.testing.expectError(error.InvalidBase, size_classes.Logarithmic.init(.{
        .base = 3,
    }));
    try std.testing.expectError(error.InvalidBase, size_classes.Logarithmic.init(.{
        .base = 129,
    }));
    try std.testing.expectError(error.InvalidMinimumTrackedSpace, size_classes.Logarithmic.init(.{
        .minimum_tracked_space = 0,
    }));
}
