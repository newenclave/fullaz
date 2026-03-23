const std = @import("std");
const radix_tree = @import("fullaz").radix_tree;

const Model = radix_tree.models.paged.Model;
const View = radix_tree.models.paged.View;

test "RadixTree paged: leaf create/format" {
    const PageView = View(u32, u16, u64, 16, std.builtin.Endian.little, false);
    const LeafSubheader = PageView.LeafSubheaderView;

    var tmp_buf = [_]u8{0} ** 4096;
    var leaf_view = LeafSubheader.init(&tmp_buf);
    try leaf_view.formatPage(0x5678, 0x9abc, 0);
    try leaf_view.check();

    try std.testing.expect(try leaf_view.slotSize() == 16);

    std.debug.print("slot size: {}\n", .{try leaf_view.slotSize()});
    std.debug.print("slot capacity: {}\n", .{try leaf_view.slotsCapacity()});
}

test "RadixTree paged: inode create/format" {
    const PageView = View(u32, u16, u64, 16, std.builtin.Endian.little, false);
    const InodeSubheader = PageView.InodeSubheaderView;

    var tmp_buf = [_]u8{0} ** 4096;
    var inode_view = InodeSubheader.init(&tmp_buf);
    try inode_view.formatPage(0x5678, 0x9abc, 0);
    try inode_view.check();

    std.debug.print("slot size: {}\n", .{try inode_view.slotSize()});
    std.debug.print("slot capacity: {}\n", .{try inode_view.slotsCapacity()});
}
