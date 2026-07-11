const std = @import("std");
const fullaz = @import("fullaz");
const rtree = fullaz.rtree;
const strategy = rtree.strategy;

const testing = std.testing;

const BB = rtree.BoundingBox(i64, 2);
const Guttman = strategy.GuttmanStrategy(BB);

fn box(x0: i64, y0: i64, x1: i64, y1: i64) BB {
    return BB.initWith(.{ x0, y0 }, .{ x1, y1 });
}

test "rtree strategy contract: Guttman satisfies assertStrategy" {
    comptime strategy.assertStrategy(Guttman, BB);
    try testing.expect(!Guttman.wants_reinsert);
}

test "Guttman chooseSubtree: least enlargement" {
    const children = [_]BB{ box(0, 0, 2, 2), box(10, 10, 12, 12) };
    // entry inside child 0 -> no enlargement there
    try testing.expectEqual(@as(usize, 0), Guttman.chooseSubtree(&children, box(1, 1, 2, 2), true));
    // entry near child 1 -> child 1 enlarges least
    try testing.expectEqual(@as(usize, 1), Guttman.chooseSubtree(&children, box(11, 11, 13, 13), true));
}

test "Guttman splitEntries: separates two clusters" {
    const mbrs = [_]BB{
        box(0, 0, 1, 1),    box(0, 0, 1, 1), // bottom-left cluster: idx 0,1
        box(10, 10, 11, 11), box(10, 10, 11, 11), box(10, 10, 11, 11), // top-right: idx 2,3,4
    };
    var assign = [_]u8{9} ** 5;
    Guttman.splitEntries(&mbrs, 2, &assign);

    // each cluster ends up wholly in one group, and the groups differ
    try testing.expectEqual(assign[0], assign[1]);
    try testing.expectEqual(assign[2], assign[3]);
    try testing.expectEqual(assign[3], assign[4]);
    try testing.expect(assign[0] != assign[2]);
}

test "Guttman splitEntries: identical boxes still respect min_fill" {
    const mbrs = [_]BB{
        box(0, 0, 1, 1), box(0, 0, 1, 1), box(0, 0, 1, 1), box(0, 0, 1, 1), box(0, 0, 1, 1),
    };
    var assign = [_]u8{9} ** 5;
    Guttman.splitEntries(&mbrs, 2, &assign);

    var c0: usize = 0;
    var c1: usize = 0;
    for (assign) |a| {
        switch (a) {
            0 => c0 += 1,
            1 => c1 += 1,
            else => unreachable,
        }
    }
    try testing.expectEqual(@as(usize, 5), c0 + c1);
    try testing.expect(c0 >= 2);
    try testing.expect(c1 >= 2);
}
