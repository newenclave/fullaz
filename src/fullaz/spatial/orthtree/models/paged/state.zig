const std = @import("std");
const PackedInt = @import("../../../../core/packed_int.zig").PackedInt;

/// Durable state required to reopen one paged orthtree.
pub fn State(
    comptime PageIdT: type,
    comptime Endian: std.builtin.Endian,
) type {
    const PackedPageId = PackedInt(PageIdT, Endian);
    const PackedSlotId = PackedInt(u16, Endian);
    const PackedCount = PackedInt(u64, Endian);
    const StateT = extern struct {
        root_page: PackedPageId = PackedPageId.init(PackedPageId.max),
        root_slot: PackedSlotId = PackedSlotId.init(0),
        entries_count: PackedCount = PackedCount.init(0),
    };

    comptime {
        if (@alignOf(StateT) != 1 or
            @offsetOf(StateT, "root_page") != 0 or
            @offsetOf(StateT, "root_slot") != @sizeOf(PackedPageId) or
            @offsetOf(StateT, "entries_count") != @sizeOf(PackedPageId) + @sizeOf(PackedSlotId) or
            @sizeOf(StateT) != @sizeOf(PackedPageId) + @sizeOf(PackedSlotId) + @sizeOf(PackedCount))
        {
            @compileError("Paged Orthtree state layout changed");
        }
    }
    return StateT;
}
