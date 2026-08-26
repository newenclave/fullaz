const std = @import("std");
const view = @import("view.zig");

pub fn scanRefs(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime forward_only: bool,
    comptime Endian: std.builtin.Endian,
    page_id: PageIdT,
    page: []const u8,
    page_kind: u16,
    visitor: anytype,
) !void {
    const View = view.ViewImpl(PageIdT, IndexT, void, forward_only, Endian, true);
    const chunk = View.Chunk.init(page);
    try chunk.pageView().validateTyped();
    const header = chunk.header();
    if (header.self_pid.get() != page_id) {
        return error.BadData;
    }
    if (header.kind.get() != page_kind) {
        return error.BadType;
    }
    if (chunk.getNext()) |next| {
        try visitor.visit(next);
    }
}
