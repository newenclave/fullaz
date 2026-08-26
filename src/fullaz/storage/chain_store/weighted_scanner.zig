const std = @import("std");
const weighted_view = @import("../../weighted_bpt/models/paged/view.zig");

fn validatePage(
    comptime PageIdT: type,
    comptime SizeT: type,
    comptime ViewT: type,
    comptime SubheaderT: type,
    page_id: PageIdT,
    page: []const u8,
    page_kind: u16,
) !ViewT {
    const result = ViewT.init(page);
    try result.page_view.validateTyped();
    const header = result.page_view.header();
    if (header.self_pid.get() != page_id) {
        return error.BadData;
    }
    if (header.kind.get() != page_kind or header.subheader_size.get() != @sizeOf(SubheaderT)) {
        return error.BadType;
    }
    const slots = try result.slotsDir();
    try slots.validate();
    _ = SizeT;
    return result;
}

pub fn scanLeafRefs(
    comptime PageIdT: type,
    comptime SizeT: type,
    comptime Endian: std.builtin.Endian,
    page_id: PageIdT,
    page: []const u8,
    page_kind: u16,
    visitor: anytype,
) !void {
    _ = visitor;
    const View = weighted_view.View(PageIdT, u16, SizeT, Endian, true);
    const leaf = try validatePage(
        PageIdT,
        SizeT,
        View.LeafSubheaderView,
        View.LeafSubheader,
        page_id,
        page,
        page_kind,
    );
    for (0..try leaf.entries()) |index| {
        const value = try leaf.get(index);
        _ = value;
    }
}

pub fn scanInodeRefs(
    comptime PageIdT: type,
    comptime SizeT: type,
    comptime Endian: std.builtin.Endian,
    page_id: PageIdT,
    page: []const u8,
    page_kind: u16,
    visitor: anytype,
) !void {
    const View = weighted_view.View(PageIdT, u16, SizeT, Endian, true);
    const inode = try validatePage(
        PageIdT,
        SizeT,
        View.InodeSubheaderView,
        View.InodeSubheader,
        page_id,
        page,
        page_kind,
    );
    for (0..try inode.entries()) |index| {
        const child = try inode.get(index);
        if (child.child == std.math.maxInt(PageIdT)) {
            return error.BadData;
        }
        try visitor.visit(child.child);
    }
}
