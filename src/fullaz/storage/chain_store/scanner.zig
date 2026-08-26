const std = @import("std");
const view = @import("view.zig");

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
    const chunk = View.Chunk.init(page);
    try chunk.page().validateTyped();
    const header = chunk.page().header();
    if (header.self_pid.get() != page_id) {
        return error.BadData;
    }
    if (header.kind.get() != page_kind or
        header.subheader_size.get() != @sizeOf(View.Chunk.SubheaderType))
    {
        return error.BadType;
    }
    const data_size: usize = @intCast(chunk.getSize());
    if (data_size > chunk.data().len) {
        return error.BadData;
    }
    if (chunk.getNext()) |next| {
        try visitor.visit(next);
    }
}
