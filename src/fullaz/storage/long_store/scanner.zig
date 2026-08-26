const std = @import("std");
const view = @import("view.zig");

fn validateHeader(
    comptime PageIdT: type,
    comptime HeaderViewT: type,
    page_id: PageIdT,
    page_kind: u16,
    page: []const u8,
) !HeaderViewT {
    const result = HeaderViewT.init(page);
    try result.pageView().validateTyped();
    const header = result.pageView().header();
    if (header.self_pid.get() != page_id) {
        return error.BadData;
    }
    if (header.kind.get() != page_kind or
        header.subheader_size.get() != @sizeOf(HeaderViewT.SubheaderType))
    {
        return error.BadType;
    }
    return result;
}

pub fn scanHeaderRefs(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime SizeT: type,
    comptime Endian: std.builtin.Endian,
    page_id: PageIdT,
    page: []const u8,
    page_kind: u16,
    visitor: anytype,
) !void {
    const View = view.View(PageIdT, IndexT, SizeT, Endian, true);
    const header = try validateHeader(
        PageIdT,
        View.HeaderView,
        page_id,
        page_kind,
        page,
    );
    if (header.link().getFwd()) |next| {
        try visitor.visit(next);
    }
}

pub fn scanChunkRefs(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime SizeT: type,
    comptime Endian: std.builtin.Endian,
    page_id: PageIdT,
    page: []const u8,
    page_kind: u16,
    visitor: anytype,
) !void {
    const View = view.View(PageIdT, IndexT, SizeT, Endian, true);
    const chunk = try validateHeader(
        PageIdT,
        View.ChunkView,
        page_id,
        page_kind,
        page,
    );
    const data_size: usize = @intCast(chunk.link().getDataSize());
    if (data_size > chunk.data().len) {
        return error.BadData;
    }
    if (chunk.link().getFwd()) |next| {
        try visitor.visit(next);
    }
}
