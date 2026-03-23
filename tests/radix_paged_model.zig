const std = @import("std");
const radix_tree = @import("fullaz").radix_tree;

const Model = radix_tree.models.paged.Model;
const View = radix_tree.models.paged.View;

test "RadixTree paged: leaf create/format" {
    const PageView = View(u32, u16, u64, 256, std.builtin.Endian.little, false);
    const LeafSubheader = PageView.LeafSubheaderView;

    var tmp_buf = [_]u8{0} ** 512;
    var leaf_view = LeafSubheader.init(&tmp_buf);
    try leaf_view.formatPage(0x5678, 0x9abc, 0);
    try leaf_view.check();
}
