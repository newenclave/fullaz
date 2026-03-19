const std = @import("std");
const radix_tree = @import("fullaz").radix_tree;

const Model = radix_tree.models.memory.Model;

test "RadixTree memory: create model" {
    const M = Model(u32, u32);
    const Tree = radix_tree.Tree(M);

    var model = try M.init(std.testing.allocator, .{
        .leaf_base = 128,
        .inode_base = 256,
    });
    defer model.deinit();
    const acc = model.getAccessor();
    var leaf = try acc.createLeaf();
    defer acc.deinitLeaf(&leaf);
    var inode = try acc.createInode();
    defer acc.deinitInode(&inode);

    var skr = try acc.splitKey(0x12345678);
    defer acc.deinitSplitKey(&skr);

    var tree = Tree.init(&model);
    defer tree.deinit();
}
