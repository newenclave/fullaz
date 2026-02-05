const std = @import("std");
const wbpt = @import("fullaz").weighted_bpt;
const algos = @import("fullaz").core.algorithm;

const MemoryModel = wbpt.models.memory.Model;

const String = std.ArrayList(u8);

// test "WBpt Leaf Create and insert" {
//     const Model = MemoryModel(u8, 4);

//     const allocator = std.testing.allocator;
//     var model = try Model.init(allocator);
//     defer model.deinit();
//     var acc = model.getAccessor();

//     var leaf = try acc.createLeaf();
//     try leaf.insertAt(0, "hello");
//     try leaf.insertAt(1, "world");
//     try leaf.insertAt(1, ", ");
//     for (0..try leaf.size()) |i| {
//         var val = try leaf.getValue(i);
//         defer val.deinit();
//         std.debug.print("Leaf Value {}: {s}\n", .{ i, try val.get() });
//     }
//     std.debug.print("Leaf can insert: {}\n", .{try leaf.canInsertWeight(10)});

//     const pos = try leaf.selectPos(6);
//     std.debug.print("Select Pos for weight 6: pos={}, weight={}, accumulated={}\n", .{ pos.pos, pos.diff, pos.accumulated });

//     var first = try leaf.getValue(0);
//     defer first.deinit();
//     var right = try first.splitOfRight(3);
//     defer right.deinit();
//     std.debug.print("After splitOfRight(3):\n", .{});
//     std.debug.print("  Right: {s}\n", .{right.asSlice()});
//     std.debug.print("  Original: {s}\n", .{first.asSlice()});
// }

test "WBpt Create with Memory model" {
    const Model = MemoryModel(u8, 16);
    const Tree = wbpt.WeightedBpt(Model);

    const allocator = std.testing.allocator;
    var model = try Model.init(allocator);
    defer model.deinit();
    var acc = model.getAccessor();
    var tree = Tree.init(&model);
    defer tree.deinit();

    var leaf = try acc.createLeaf();
    var load_leaf = try acc.loadLeaf(leaf.id());

    try std.testing.expect(leaf.id() == load_leaf.id());

    defer acc.deinitLeaf(&leaf);
    defer acc.deinitLeaf(&load_leaf);
    try std.testing.expect(try acc.isLeaf(leaf.id()));
}

test "WBpt: insertion weight into a list" {
    const Model = MemoryModel(u8, 4);

    const allocator = std.testing.allocator;
    var model = try Model.init(allocator);
    defer model.deinit();
    var acc = model.getAccessor();

    var leaf = try acc.createLeaf();
    defer acc.deinitLeaf(&leaf);

    try leaf.insertWeight(0, "Hello world");
    try leaf.insertWeight(6, "Zig is great");
    for (0..try leaf.size()) |i| {
        var val = try leaf.getValue(i);
        defer val.deinit();
        std.debug.print("Leaf Value {}: {s}\n", .{ i, try val.get() });
    }
}

test "WBpt: create inode" {
    const Model = MemoryModel(u8, 4);

    const allocator = std.testing.allocator;
    var model = try Model.init(allocator);
    defer model.deinit();
    var acc = model.getAccessor();

    var inode = try acc.createInode();
    defer acc.deinitInode(&inode);
}

test "WBpt: insertion" {
    const Model = MemoryModel(u8, 4);
    const Tree = wbpt.WeightedBpt(Model);

    const allocator = std.testing.allocator;
    var model = try Model.init(allocator);
    defer model.deinit();

    var tree = Tree.init(&model);
    defer tree.deinit();

    _ = try tree.insert(0, "Hello world");
    _ = try tree.insert(5, ",");
    _ = try tree.insert(15, "!");

    var acc = model.getAccessor();
    var leaf = try acc.loadLeaf(0);
    defer acc.deinitLeaf(&leaf);
    for (0..try leaf.size()) |i| {
        var val = try leaf.getValue(i);
        defer val.deinit();
        std.debug.print("Leaf Value {}: {s}\n", .{ i, try val.get() });
    }
}
