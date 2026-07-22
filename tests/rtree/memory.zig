const std = @import("std");
const fullaz = @import("fullaz");
const rtree = fullaz.rtree;
const interfaces = rtree.models.interfaces;

const testing = std.testing;

// CoordT=i64, dims=2, ValueT=u64, max_entries=4
const Model = rtree.models.Memory(i64, 2, u64, 4);
const Key = Model.KeyType;

fn box(x0: i64, y0: i64, x1: i64, y1: i64) Key {
    return Key.initWith(.{ x0, y0 }, .{ x1, y1 });
}

test "rtree memory model satisfies the contract" {
    comptime interfaces.assertModel(Model);
}

test "rtree memory model: leaf create/insert/read/nodeMbr" {
    var m = try Model.init(testing.allocator);
    defer m.deinit();
    const acc = m.getAccessor();

    var leaf = try acc.createLeaf();
    defer acc.deinitLeaf(leaf);

    try testing.expectEqual(@as(usize, 0), try leaf.size());
    try testing.expectEqual(@as(usize, 4), try leaf.capacity());
    try testing.expect(try leaf.canInsertEntry(box(0, 0, 1, 1), 1));

    try leaf.insertEntry(box(0, 0, 2, 2), 100);
    try leaf.insertEntry(box(1, 1, 3, 3), 200);
    try testing.expectEqual(@as(usize, 2), try leaf.size());
    try testing.expectEqual(@as(u64, 100), try leaf.getValue(0));
    try testing.expectEqual(box(1, 1, 3, 3), try leaf.getMbr(1));
    // union of the two entries
    try testing.expectEqual(box(0, 0, 3, 3), try leaf.nodeMbr());

    try leaf.erase(0);
    try testing.expectEqual(@as(usize, 1), try leaf.size());
    try testing.expectEqual(@as(u64, 200), try leaf.getValue(0));

    try testing.expectError(Model.Error.OutOfBounds, leaf.getValue(5));
}

test "rtree memory model: leaf fills to capacity then reports full" {
    var m = try Model.init(testing.allocator);
    defer m.deinit();
    const acc = m.getAccessor();
    var leaf = try acc.createLeaf();
    defer acc.deinitLeaf(leaf);

    for (0..4) |i| {
        try leaf.insertEntry(box(0, 0, 1, 1), @intCast(i));
    }
    try testing.expect(!try leaf.canInsertEntry(box(0, 0, 1, 1), 9));
    try testing.expectError(Model.Error.NodeFull, leaf.insertEntry(box(0, 0, 1, 1), 9));

    try leaf.clear();
    try testing.expectEqual(@as(usize, 0), try leaf.size());
}

test "rtree memory model: inode children, level, updateChildMbr, parent" {
    var m = try Model.init(testing.allocator);
    defer m.deinit();
    const acc = m.getAccessor();

    var child = try acc.createLeaf();
    defer acc.deinitLeaf(child);

    var inode = try acc.createInode();
    defer acc.deinitInode(inode);

    try inode.setLevel(1);
    try testing.expectEqual(@as(usize, 1), try inode.getLevel());

    try inode.insertChild(box(0, 0, 2, 2), child.id());
    try testing.expectEqual(@as(usize, 1), try inode.size());
    try testing.expectEqual(child.id(), try inode.getChild(0));
    try testing.expectEqual(box(0, 0, 2, 2), try inode.getMbr(0));

    try inode.updateChildMbr(0, box(0, 0, 5, 5));
    try testing.expectEqual(box(0, 0, 5, 5), try inode.getMbr(0));

    try child.setParent(inode.id());
    try testing.expectEqual(inode.id(), (try child.getParent()).?);
}

test "rtree memory model: load kind mismatch is null, isLeafId, destroy, root" {
    var m = try Model.init(testing.allocator);
    defer m.deinit();
    const acc = m.getAccessor();

    var leaf = try acc.createLeaf();
    const leaf_id = leaf.id();
    acc.deinitLeaf(leaf);

    var inode = try acc.createInode();
    const inode_id = inode.id();
    acc.deinitInode(inode);

    try testing.expect(try acc.isLeafId(leaf_id));
    try testing.expect(!try acc.isLeafId(inode_id));

    // loadInode on a leaf id -> null (wrong kind); null id -> null
    try testing.expect((try acc.loadInode(leaf_id)) == null);
    try testing.expect((try acc.loadLeaf(null)) == null);
    if (try acc.loadLeaf(leaf_id)) |l| {
        acc.deinitLeaf(l);
    } else {
        try testing.expect(false);
    }

    try acc.setRoot(inode_id);
    try testing.expectEqual(inode_id, acc.getRoot().?);

    try acc.destroy(leaf_id);
    try testing.expect((try acc.loadLeaf(leaf_id)) == null); // destroyed slot
}
