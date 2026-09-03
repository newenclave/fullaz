const PackedInt = @import("../../../core/packed_int.zig").PackedInt;

/// Durable external state required to reopen one paged garbage collector.
pub fn State(comptime PageIdT: type) type {
    const PackedPageId = PackedInt(PageIdT, .little);
    const StateT = extern struct {
        state_page_root: PackedPageId = PackedPageId.init(PackedPageId.max),
    };

    comptime {
        if (@alignOf(StateT) != 1 or
            @offsetOf(StateT, "state_page_root") != 0 or
            @sizeOf(StateT) != @sizeOf(PackedPageId))
        {
            @compileError("Paged GC external state layout changed");
        }
    }
    return StateT;
}
