const std = @import("std");
const view = @import("models/paged/view.zig");

pub fn scanLeafRefs(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime Endian: std.builtin.Endian,
    page_id: PageIdT,
    page: []const u8,
    page_kind: u16,
    key_size: usize,
    comparator_id: u32,
    visitor: anytype,
) !void {
    const View = view.View(PageIdT, IndexT, Endian, true);
    const leaf = View.Leaf.init(page);
    try leaf.validatePage(page_id, page_kind, key_size, comparator_id);
    if (visitor.hasValueScanner()) {
        for (0..try leaf.entries()) |index| {
            try visitor.visitValue((try leaf.get(index)).value);
        }
    }
}

pub fn scanInodeRefs(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime Endian: std.builtin.Endian,
    page_id: PageIdT,
    page: []const u8,
    page_kind: u16,
    key_size: usize,
    comparator_id: u32,
    visitor: anytype,
) !void {
    const View = view.View(PageIdT, IndexT, Endian, true);
    const inode = View.Inode.init(page);
    try inode.validatePage(page_id, page_kind, key_size, comparator_id);
    for (0..try inode.entries()) |index| {
        try visitor.visit((try inode.get(index)).child_pid);
    }
}
