const fullaz = @import("fullaz");
const std = @import("std");

const Box = fullaz.rtree.BoundingBox(i64, 2);
const Tree = fullaz.aabb_tree.Tree(Box, u64);

test "aabb tree module imports" {
    _ = fullaz.aabb_tree;
}

test "aabb tree initializes empty" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    try std.testing.expect(tree.empty());
    try std.testing.expectEqual(@as(usize, 0), tree.count());
}

test "aabb tree box contract accepts rtree bounding box" {
    comptime fullaz.aabb_tree.assertBox(Box);
}

test "aabb tree fat box contract accepts rtree bounding box" {
    comptime fullaz.aabb_tree.assertFatBox(Box);
}
