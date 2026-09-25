const std = @import("std");
const radix_tree = @import("fullaz").radix_tree;
const printer = @import("test_printer");

const Model = radix_tree.models.memory.Model;

const StdOut = struct {
    const Self = @This();
    pub fn print(_: *const Self, comptime fmt: []const u8, args: anytype) !void {
        printer.print(fmt, args);
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
    const acc = model.accessor();
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

test "RadixTree memory: reuses slots from partial leaves" {
    const M = Model(u32, u32);
    const Tree = radix_tree.Tree(M);

    var model = try M.init(std.testing.allocator, .{
        .leaf_base = 4,
        .inode_base = 4,
    });
    defer model.deinit();
    var tree = Tree.init(&model);
    defer tree.deinit();

    try tree.set(1, 11);
    try std.testing.expectEqual(@as(?u32, 0), try tree.takeFree(10));
    try std.testing.expectEqual(@as(?u32, 2), try tree.takeFree(12));
    try std.testing.expectEqual(@as(?u32, 3), try tree.takeFree(13));
    try std.testing.expectEqual(@as(?u32, null), try tree.takeFree(99));

    try tree.free(2);
    try std.testing.expectEqual(@as(?u32, 2), try tree.takeFree(22));
    try std.testing.expectEqual(@as(?u32, 22), (try tree.get(2)).?);

    try tree.free(0);
    try tree.free(1);
    try tree.free(2);
    try tree.free(3);
    try std.testing.expectEqual(@as(?u32, null), try tree.takeFree(1));
}

test "RadixTree memory: value editor finishes or rolls back and blocks mutations" {
    const M = Model(u32, u32);
    const Tree = radix_tree.Tree(M);

    var model = try M.init(std.testing.allocator, .{
        .leaf_base = 4,
        .inode_base = 4,
    });
    defer model.deinit();
    var tree = Tree.init(&model);
    defer tree.deinit();

    try tree.set(1, 10);
    var editor = (try tree.openValueEditor(1)).?;
    (try editor.valueMut()).* = 20;
    try std.testing.expectError(error.ValueEditorActive, tree.set(2, 2));
    try std.testing.expectError(error.ValueEditorActive, tree.openValueEditor(1));
    editor.deinit();
    try std.testing.expectEqual(@as(?u32, 10), try tree.get(1));

    var finished = (try tree.openValueEditor(1)).?;
    (try finished.valueMut()).* = 30;
    try finished.finish();
    try std.testing.expectError(error.EditorInvalidated, finished.valueMut());
    try std.testing.expectEqual(@as(?u32, 30), try tree.get(1));
}

test "RadixTree memory: point entries block mutations and editors outlive entries" {
    const M = Model(u32, u32);
    const Tree = radix_tree.Tree(M);

    var model = try M.init(std.testing.allocator, .{
        .leaf_base = 4,
        .inode_base = 4,
    });
    defer model.deinit();
    var tree = Tree.init(&model);
    defer tree.deinit();

    try tree.set(1, 10);
    const const_tree: *const Tree = &tree;
    try std.testing.expect((try const_tree.find(2)) == null);
    try tree.set(2, 30);

    var entry = (try const_tree.find(1)).?;
    defer entry.deinit();
    const found = try entry.get();
    try std.testing.expectEqual(@as(u32, 1), found.key);
    try std.testing.expectEqual(@as(u32, 10), found.value);

    const generation = model.structuralMutationCoordinator().generation();
    try std.testing.expectError(error.ReadHandleActive, tree.free(1));
    try std.testing.expectError(error.ReadHandleActive, tree.set(2, 31));
    try std.testing.expectError(error.ReadHandleActive, tree.destroy());
    try std.testing.expectEqual(generation, model.structuralMutationCoordinator().generation());
    try std.testing.expectEqual(@as(u32, 10), (try entry.get()).value);
    try std.testing.expectEqual(@as(?u32, 30), try tree.get(2));

    var other_entry = (try const_tree.find(2)).?;
    defer other_entry.deinit();
    var editor = try entry.editValue();
    defer editor.deinit();
    entry.deinit();
    try std.testing.expectError(error.InvalidHandle, entry.get());
    try std.testing.expectError(error.InvalidHandle, entry.editValue());
    try std.testing.expectError(error.ReadHandleActive, tree.set(2, 31));
    other_entry.deinit();
    (try editor.valueMut()).* = 20;
    try std.testing.expectError(error.ValueEditorActive, tree.set(2, 31));
    try editor.finish();
    try std.testing.expectEqual(@as(?u32, 20), try tree.get(1));

    try tree.free(1);
    try tree.set(1, 40);
    try tree.destroy();
    try std.testing.expectEqual(@as(?usize, null), try model.accessor().getRoot());
}

test "RadixTree memory: destroy releases a deep sparse tree and its free leaves" {
    const M = Model(u32, u32);
    const Tree = radix_tree.Tree(M);

    var model = try M.init(std.testing.allocator, .{
        .leaf_base = 4,
        .inode_base = 4,
    });
    defer model.deinit();
    var tree = Tree.init(&model);
    defer tree.deinit();

    try tree.set(1, 11);
    try tree.set(64, 64);
    try tree.set(std.math.maxInt(u32), 99);
    try std.testing.expect((try model.accessor().getRootLevel()).? > 2);
    try std.testing.expect(model.accessor().free_leaf_ids.count() >= 3);
    const node_count = model.accessor().cont.items.len;

    try tree.destroy();
    try std.testing.expectEqual(@as(?usize, null), try model.accessor().getRoot());
    try std.testing.expectEqual(@as(usize, 0), model.accessor().free_leaf_ids.count());
    try std.testing.expectEqual(@as(?u32, null), try tree.get(1));
    try std.testing.expectEqual(@as(?u32, null), try tree.takeFree(1));
    for (0..node_count) |node_id| {
        try std.testing.expectError(error.InvalidId, model.accessor().isLeaf(node_id));
    }

    try tree.destroy();
}
