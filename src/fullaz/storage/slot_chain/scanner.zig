const std = @import("std");
const view = @import("view.zig");

const tombstone_flag: u16 = 1 << 0;

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
    try chunk.view.pageView().validateTyped();
    const header = chunk.view.header();
    if (header.self_pid.get() != page_id) {
        return error.BadData;
    }
    if (header.kind.get() != page_kind) {
        return error.BadType;
    }

    const slots = try chunk.slotsDir();
    try slots.validate();
    for (0..slots.entries().len) |slot_id| {
        if (!try slots.isAllocated(slot_id)) {
            continue;
        }
        const flags = try slots.getFlags(slot_id);
        if ((flags & @as(IndexT, tombstone_flag)) == 0 and visitor.hasValueScanner()) {
            try visitor.visitValue(try slots.get(slot_id));
        }
    }
    if (chunk.getNext()) |next| {
        try visitor.visit(next);
    }
}
