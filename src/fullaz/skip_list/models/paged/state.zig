const std = @import("std");
const PackedInt = @import("../../../core/packed_int.zig").PackedInt;

/// Durable roots required to reopen one paged skip list.
pub fn State(
    comptime PageIdT: type,
    comptime maximum_level: usize,
    comptime Endian: std.builtin.Endian,
) type {
    if (maximum_level == 0) {
        @compileError("Paged SkipList maximum_level must be greater than zero");
    }
    if (maximum_level > std.math.maxInt(u8)) {
        @compileError("Paged SkipList maximum_level must fit in the persisted node level");
    }

    const PackedPageId = PackedInt(PageIdT, Endian);
    const PackedSlotId = PackedInt(u16, Endian);
    const Root = extern struct {
        page_id: PackedPageId = PackedPageId.init(PackedPageId.max),
        slot_id: PackedSlotId = PackedSlotId.init(PackedSlotId.max),
    };
    const Roots = [maximum_level]Root;
    const StateT = extern struct {
        roots: Roots = .{@as(Root, .{})} ** maximum_level,
    };

    comptime {
        if (@alignOf(StateT) != 1 or
            @offsetOf(StateT, "roots") != 0 or
            @sizeOf(StateT) != maximum_level * @sizeOf(Root))
        {
            @compileError("Paged SkipList state layout changed");
        }
    }
    return StateT;
}
