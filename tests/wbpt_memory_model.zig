const std = @import("std");
const wbpt = @import("fullaz").weighted_bpt;
const algos = @import("fullaz").core.algorithm;

const MemoryModel = wbpt.models.memory.Model;

const String = std.ArrayList(u8);

test "WBpt Leaf Create and insert" {
    const Model = MemoryModel(u8, 4);

    const allocator = std.testing.allocator;
    var model = try Model.init(allocator);
    defer model.deinit();
    var acc = model.getAccessor();

    var leaf = try acc.createLeaf();
    try leaf.insertAt(0, "hello");
    try leaf.insertAt(1, "world");
    try leaf.insertAt(1, ", ");
    for (0..try leaf.size()) |i| {
        var val = try leaf.getValue(i);
        defer val.deinit();
        std.debug.print("Leaf Value {}: {s}\n", .{ i, val.asSlice() });
    }
    std.debug.print("Leaf can insert: {}\n", .{try leaf.canInsertWeight(10)});

    const pos = try leaf.selectPos(6);
    std.debug.print("Select Pos for weight 6: pos={}, weight={}, accumulated={}\n", .{ pos.pos, pos.diff, pos.accumulated });

    var first = try leaf.getValue(0);
    defer first.deinit();
    var left = try first.splitOfLeft(3);
    defer left.deinit();
    std.debug.print("After splitOfLeft(3):\n", .{});
    std.debug.print("  Left: {s}\n", .{left.asSlice()});
    std.debug.print("  Original: {s}\n", .{first.asSlice()});
}

test "WBpt Create with Memory model" {
    const Model = MemoryModel(u8, 16);
    const Tree = wbpt.WeightedBpt(Model);

    const allocator = std.testing.allocator;
    var model = try Model.init(allocator);
    defer model.deinit();
    var acc = model.getAccessor();
    var tree = Tree.init(&model);
    defer tree.deinit();

    const leaf = try acc.createLeaf();
    const load_leaf = try acc.loadLeaf(leaf.id());

    try std.testing.expect(leaf.id() == load_leaf.?.id());

    defer acc.deinitLeaf(leaf);
    defer acc.deinitLeaf(load_leaf.?);
    try std.testing.expect(try acc.isLeaf(leaf.id()));
}
