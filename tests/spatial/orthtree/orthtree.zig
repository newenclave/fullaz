const std = @import("std");
const fulla = @import("fullaz");
const orthtree = fulla.spatial.orthtree;

fn expectChildBounds(comptime Coord: type) !void {
    const Model = orthtree.models.Memory(Coord, 2);
    const TreeType = orthtree.tree.TreeImpl(Model);
    const Box = Model.Box;

    const parent = Box.create(.{ 0, 0 }, .{ 10, 10 });
    const expected = [_]Box{
        Box.create(.{ 0, 0 }, .{ 5, 5 }),
        Box.create(.{ 5, 0 }, .{ 10, 5 }),
        Box.create(.{ 0, 5 }, .{ 5, 10 }),
        Box.create(.{ 5, 5 }, .{ 10, 10 }),
    };

    inline for (expected, 0..) |expected_bounds, i| {
        try std.testing.expect(std.meta.eql(expected_bounds, TreeType.childBounds(&parent, i)));
    }
}

fn expectChildIndexFor(comptime Coord: type) !void {
    const Model = orthtree.models.Memory(Coord, 2);
    const TreeType = orthtree.tree.TreeImpl(Model);
    const Box = Model.Box;

    const parent = Box.create(.{ 0, 0 }, .{ 10, 10 });
    inline for (0..TreeType.child_count) |i| {
        const child_bounds = TreeType.childBounds(&parent, i);
        try std.testing.expectEqual(i, TreeType.childIndexFor(&parent, &child_bounds).?);
    }

    const crosses_x = Box.create(.{ 4, 1 }, .{ 6, 4 });
    const crosses_y = Box.create(.{ 1, 4 }, .{ 4, 6 });
    const outside_parent = Box.create(.{ 9, 1 }, .{ 11, 4 });
    try std.testing.expect(TreeType.childIndexFor(&parent, &crosses_x) == null);
    try std.testing.expect(TreeType.childIndexFor(&parent, &crosses_y) == null);
    try std.testing.expect(TreeType.childIndexFor(&parent, &outside_parent) == null);
}

fn expectSplitNode(comptime Coord: type) !void {
    const Model = orthtree.models.Memory(Coord, 2);
    const TreeType = orthtree.tree.TreeImpl(Model);
    const Box = Model.Box;

    var model = try Model.init(std.testing.allocator, 8);
    defer model.deinit();

    var tree = TreeType.init(&model);
    const acc = model.getAccessor();
    var node = try acc.createNode(Box.create(.{ 0, 0 }, .{ 10, 10 }));
    const parent_id = node.id();
    const parent_bounds = node.bounds();
    const entries = [_]Box{
        Box.create(.{ 1, 1 }, .{ 2, 2 }),
        Box.create(.{ 6, 1 }, .{ 7, 2 }),
        Box.create(.{ 1, 6 }, .{ 2, 7 }),
        Box.create(.{ 6, 6 }, .{ 7, 7 }),
        Box.create(.{ 4, 1 }, .{ 6, 2 }),
    };

    inline for (entries, 0..) |entry_box, i| {
        _ = i;
        try node.addEntry(entry_box, 0);
    }
    try tree.splitNode(&node);

    var parent = try acc.loadNode(parent_id);
    defer acc.deinitNode(&parent);
    try std.testing.expect(!parent.isLeaf());
    try std.testing.expectEqual(@as(usize, 1), parent.size());
    try std.testing.expect(std.meta.eql(entries[4], (try parent.getEntry(0)).getBox()));

    inline for (0..TreeType.child_count) |i| {
        const child_id = parent.getChild(i).?;
        var child = try acc.loadNode(child_id);
        defer acc.deinitNode(&child);

        try std.testing.expect(child.isLeaf());
        try std.testing.expectEqual(parent_id, (try child.getParent()).?);
        try std.testing.expect(std.meta.eql(TreeType.childBounds(&parent_bounds, i), child.bounds()));
        try std.testing.expectEqual(@as(usize, 1), child.size());
        try std.testing.expect(std.meta.eql(entries[i], (try child.getEntry(0)).getBox()));
    }
}

fn expectInsert(comptime Coord: type) !void {
    const Model = orthtree.models.Memory(Coord, 2);
    const TreeType = orthtree.tree.TreeImpl(Model);
    const Box = Model.Box;

    var model = try Model.init(std.testing.allocator, 1);
    defer model.deinit();

    var tree = TreeType.init(&model);
    const acc = model.getAccessor();
    const first = Box.create(.{ 0, 0 }, .{ 10, 10 });
    const second = Box.create(.{ 1, 1 }, .{ 2, 2 });

    try tree.insert(first, 1);
    try tree.insert(second, 2);

    const root_id = acc.getRoot().?;
    var root = try acc.loadNode(root_id);
    defer acc.deinitNode(&root);
    try std.testing.expect(!root.isLeaf());
    try std.testing.expectEqual(@as(usize, 1), root.size());
    try std.testing.expect(std.meta.eql(first, (try root.getEntry(0)).getBox()));

    const child_id = root.getChild(0).?;
    var child = try acc.loadNode(child_id);
    defer acc.deinitNode(&child);
    try std.testing.expectEqual(root_id, (try child.getParent()).?);
    try std.testing.expectEqual(@as(usize, 1), child.size());
    try std.testing.expect(std.meta.eql(second, (try child.getEntry(0)).getBox()));
}

fn expectInsertGrowsRoot(comptime Coord: type) !void {
    const Model = orthtree.models.Memory(Coord, 2);
    const TreeType = orthtree.tree.TreeImpl(Model);
    const Box = Model.Box;

    var model = try Model.init(std.testing.allocator, 8);
    defer model.deinit();

    var tree = TreeType.init(&model);
    const acc = model.getAccessor();
    const first = Box.create(.{ 0, 0 }, .{ 2, 2 });
    const second = Box.create(.{ 3, 3 }, .{ 4, 4 });

    try tree.insert(first, 1);
    try tree.insert(second, 2);

    const root_id = acc.getRoot().?;
    var root = try acc.loadNode(root_id);
    defer acc.deinitNode(&root);
    try std.testing.expect(std.meta.eql(Box.create(.{ 0, 0 }, .{ 4, 4 }), root.bounds()));
    try std.testing.expectEqual(@as(usize, 0), root.size());

    const old_root_id = root.getChild(0).?;
    var old_root = try acc.loadNode(old_root_id);
    defer acc.deinitNode(&old_root);
    try std.testing.expectEqual(root_id, (try old_root.getParent()).?);
    try std.testing.expectEqual(@as(usize, 1), old_root.size());
    try std.testing.expect(std.meta.eql(first, (try old_root.getEntry(0)).getBox()));

    var new_entry_child = try acc.loadNode(root.getChild(3).?);
    defer acc.deinitNode(&new_entry_child);
    try std.testing.expectEqual(@as(usize, 1), new_entry_child.size());
    try std.testing.expect(std.meta.eql(second, (try new_entry_child.getEntry(0)).getBox()));
}

fn expectQuery(comptime Coord: type) !void {
    const Model = orthtree.models.Memory(Coord, 2);
    const TreeType = orthtree.tree.TreeImpl(Model);
    const Box = Model.Box;
    const QueryContext = struct {
        values: [3]Coord = undefined,
        len: usize = 0,

        fn callback(ctx: *@This(), entry_box: Box, value: Coord) !void {
            _ = entry_box;
            ctx.values[ctx.len] = value;
            ctx.len += 1;
        }

        fn contains(ctx: *const @This(), value: Coord) bool {
            for (ctx.values[0..ctx.len]) |result| {
                if (result == value) {
                    return true;
                }
            }
            return false;
        }
    };

    var model = try Model.init(std.testing.allocator, 1);
    defer model.deinit();

    var tree = TreeType.init(&model);
    try tree.insert(Box.create(.{ 0, 0 }, .{ 10, 10 }), 1);
    try tree.insert(Box.create(.{ 1, 1 }, .{ 2, 2 }), 2);
    try tree.insert(Box.create(.{ 6, 6 }, .{ 7, 7 }), 3);

    var lower_results = QueryContext{};
    try tree.query(Box.create(.{ 0, 0 }, .{ 3, 3 }), QueryContext.callback, &lower_results);
    try std.testing.expectEqual(@as(usize, 2), lower_results.len);
    try std.testing.expect(lower_results.contains(1));
    try std.testing.expect(lower_results.contains(2));

    var upper_results = QueryContext{};
    try tree.query(Box.create(.{ 5, 5 }, .{ 8, 8 }), QueryContext.callback, &upper_results);
    try std.testing.expectEqual(@as(usize, 2), upper_results.len);
    try std.testing.expect(upper_results.contains(1));
    try std.testing.expect(upper_results.contains(3));

    var empty_results = QueryContext{};
    try tree.query(Box.create(.{ 11, 11 }, .{ 12, 12 }), QueryContext.callback, &empty_results);
    try std.testing.expectEqual(@as(usize, 0), empty_results.len);
}

test "OrthTree: create" {
    _ = fulla.spatial.orthtree;
}

test "OrthTree: memory model" {
    const Model = orthtree.models.Memory(u32, 2);
    const TreeType = orthtree.tree.TreeImpl(Model);
    const Box = Model.Box;

    const allocator = std.testing.allocator;

    var model = try Model.init(allocator, 8);
    defer model.deinit();

    const tree = TreeType.init(&model);

    _ = tree;
    const acc = model.getAccessor();
    const node = try acc.createNode(Box.create(
        .{ 0, 0 },
        .{ 10, 10 },
    ));
    _ = node;
}

test "OrthTree: child bounds for u32" {
    try expectChildBounds(u32);
}

test "OrthTree: child bounds for f32" {
    try expectChildBounds(f32);
}

test "OrthTree: child index for u32" {
    try expectChildIndexFor(u32);
}

test "OrthTree: child index for f32" {
    try expectChildIndexFor(f32);
}

test "OrthTree: split node for u32" {
    try expectSplitNode(u32);
}

test "OrthTree: split node for f32" {
    try expectSplitNode(f32);
}

test "OrthTree: insert for u32" {
    try expectInsert(u32);
}

test "OrthTree: insert for f32" {
    try expectInsert(f32);
}

test "OrthTree: insert grows root for u32" {
    try expectInsertGrowsRoot(u32);
}

test "OrthTree: insert grows root for f32" {
    try expectInsertGrowsRoot(f32);
}

test "OrthTree: query for u32" {
    try expectQuery(u32);
}

test "OrthTree: query for f32" {
    try expectQuery(f32);
}
