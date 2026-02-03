const std = @import("std");
const wbpt = @import("fullaz").weighted_bpt;
const algos = @import("fullaz").core.algorithm;

const MemoryModel = wbpt.models.memory.Model;

const String = std.ArrayList(u8);

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
