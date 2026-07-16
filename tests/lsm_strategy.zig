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

test "LSM SizeTieredStrategy satisfies the compaction-strategy contract" {
    comptime strategy.assertCompactionStrategy(strategy.SizeTieredStrategy(usize), usize);
}

test "LSM SizeTieredStrategy: a qualifying contiguous tier merges, the outlier is left alone" {
    const allocator = std.testing.allocator;
    const Strategy = strategy.SizeTieredStrategy(usize);

    // growth_factor=4: sizes 5,6,7,8 all land in tier 1 ([4,15]); 200 is tier 3.
    const runs = [_]RunInfo{
        .{ .id = 3, .byte_size = 5, .count = 1 },
        .{ .id = 2, .byte_size = 6, .count = 1 },
        .{ .id = 1, .byte_size = 7, .count = 1 },
        .{ .id = 0, .byte_size = 8, .count = 1 },
        .{ .id = 99, .byte_size = 200, .count = 1 },
    };
    const ids = try Strategy.planAfterFlush(allocator, &runs);
    defer allocator.free(ids);

    try std.testing.expectEqualSlices(usize, &.{ 3, 2, 1, 0 }, ids);
}

test "LSM SizeTieredStrategy: no tier has enough runs plans nothing" {
    const allocator = std.testing.allocator;
    const Strategy = strategy.SizeTieredStrategy(usize);

    // Each run lands in a different tier -- every contiguous same-tier
    // block has length 1, below min_tier_runs.
    const runs = [_]RunInfo{
        .{ .id = 3, .byte_size = 1, .count = 1 },
        .{ .id = 2, .byte_size = 10, .count = 1 },
        .{ .id = 1, .byte_size = 50, .count = 1 },
        .{ .id = 0, .byte_size = 200, .count = 1 },
    };
    const ids = try Strategy.planAfterFlush(allocator, &runs);
    defer allocator.free(ids);

    try std.testing.expectEqual(@as(usize, 0), ids.len);
}

test "LSM SizeTieredStrategy: non-adjacent same-tier runs are not merged into one span" {
    const allocator = std.testing.allocator;
    const Strategy = strategy.SizeTieredStrategy(usize);

    // Two tier-1 blocks (sizes 5,6 and 7,8,9,10) separated by one tier-3
    // run (size 100). The blocks must stay separate -- same tier value,
    // but not adjacent -- and the longer (second) block wins.
    const runs = [_]RunInfo{
        .{ .id = 6, .byte_size = 5, .count = 1 },
        .{ .id = 5, .byte_size = 6, .count = 1 },
        .{ .id = 4, .byte_size = 100, .count = 1 },
        .{ .id = 3, .byte_size = 7, .count = 1 },
        .{ .id = 2, .byte_size = 8, .count = 1 },
        .{ .id = 1, .byte_size = 9, .count = 1 },
        .{ .id = 0, .byte_size = 10, .count = 1 },
    };
    const ids = try Strategy.planAfterFlush(allocator, &runs);
    defer allocator.free(ids);

    try std.testing.expectEqualSlices(usize, &.{ 3, 2, 1, 0 }, ids);
}
