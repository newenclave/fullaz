const std = @import("std");
const radix_tree = @import("fullaz").radix_tree;

const Model = radix_tree.models.memory.Model;

const StdOut = struct {
    const Self = @This();
    pub fn print(_: *const Self, comptime fmt: []const u8, args: anytype) !void {
        std.debug.print(fmt, args);
    }
};

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

    try tree.set(0x12, 12345678);
    try tree.set(0x0, 0);
    try tree.set(0x12345678, 87654321);
    try tree.set(0x12345677, 77654321);
    try tree.free(0x0);
    try tree.set(0x3456, 6666);
    try tree.set(0x00, 0);
    try tree.set(0xFFFFFFFF, 0xFFFFFFFF);
    try tree.set(0x12345679, 99999); // Adjacent to 0x12345678
    try tree.set(0x12345680, 88888); // Also nearby
    try tree.set(0x12340000, 77777); // Same digit[3] and digit[2]

    try tree.dumpTree(StdOut{});
}
