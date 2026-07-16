const std = @import("std");
const fullaz = @import("fullaz");
const strategy = fullaz.lsm.strategy;

const RunInfo = strategy.RunInfo(usize);

test "LSM NaiveMergeAllStrategy satisfies the compaction-strategy contract" {
    comptime strategy.assertCompactionStrategy(strategy.NaiveMergeAllStrategy(usize), usize);
}

test "LSM NaiveMergeAllStrategy: fewer than two runs plans nothing" {
    const allocator = std.testing.allocator;
    const Strategy = strategy.NaiveMergeAllStrategy(usize);

    {
        const runs = [_]RunInfo{};
        const ids = try Strategy.planAfterFlush(allocator, &runs);
        defer allocator.free(ids);
        try std.testing.expectEqual(@as(usize, 0), ids.len);
    }
    {
        const runs = [_]RunInfo{.{ .id = 0, .byte_size = 10, .count = 1 }};
        const ids = try Strategy.planAfterFlush(allocator, &runs);
        defer allocator.free(ids);
        try std.testing.expectEqual(@as(usize, 0), ids.len);
    }
}

test "LSM NaiveMergeAllStrategy: two or more runs plans all of them, order preserved" {
    const allocator = std.testing.allocator;
    const Strategy = strategy.NaiveMergeAllStrategy(usize);

    const runs = [_]RunInfo{
        .{ .id = 5, .byte_size = 100, .count = 10 },
        .{ .id = 3, .byte_size = 200, .count = 20 },
        .{ .id = 0, .byte_size = 300, .count = 30 },
    };
    const ids = try Strategy.planAfterFlush(allocator, &runs);
    defer allocator.free(ids);

    try std.testing.expectEqualSlices(usize, &.{ 5, 3, 0 }, ids);
}
