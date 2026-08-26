const std = @import("std");
const view = @import("view.zig");
const page = @import("page.zig");

pub fn scanRefs(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime SizeClassT: type,
    comptime Endian: std.builtin.Endian,
    page_id: PageIdT,
    page_bytes: []const u8,
    page_kind: u16,
    size_class: SizeClassT,
    visitor: anytype,
) !void {
    const View = view.View(PageIdT, IndexT, SizeClassT, Endian, true).SlabPageView;
    const Format = page.Fsm(PageIdT, IndexT, SizeClassT, Endian);
    const slab = View.init(page_bytes);
    try slab.validateTyped();
    const header = slab.pageHeader();
    if (header.self_pid.get() != page_id) {
        return error.BadData;
    }
    if (header.kind.get() != page_kind or slab.sizeClass() != size_class) {
        return error.BadType;
    }

    const slots = try slab.slotsDir();
    try slots.validate();
    if (try slots.slotSize() != @sizeOf(Format.Slot)) {
        return error.BadData;
    }
    for (0..try slots.capacity()) |slot_index| {
        if (!try slots.isSet(slot_index)) {
            continue;
        }
        const bytes = try slots.get(slot_index);
        const slot: *const Format.Slot = @ptrCast(@alignCast(bytes.ptr));
        if (slot.pid.isMax()) {
            return error.BadData;
        }
        try visitor.visit(slot.pid.get());
    }
    if (slab.getNext()) |next| {
        try visitor.visit(next);
    }
}
