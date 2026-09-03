const PackedInt = @import("../../core/packed_int.zig").PackedInt;

/// Durable state required to reopen one long store.
pub fn State(comptime PageIdT: type) type {
    const PackedPageId = PackedInt(PageIdT, .little);
    const StateT = extern struct {
        root: PackedPageId = PackedPageId.init(PackedPageId.max),
    };

    comptime {
        if (@alignOf(StateT) != 1 or
            @offsetOf(StateT, "root") != 0 or
            @sizeOf(StateT) != @sizeOf(PackedPageId))
        {
            @compileError("LongStore state layout changed");
        }
    }
    return StateT;
}
