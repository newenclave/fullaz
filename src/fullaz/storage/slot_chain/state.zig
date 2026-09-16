const std = @import("std");
const PackedInt = @import("../../core/packed_int.zig").PackedInt;
const page_chain = @import("../page_chain/page_chain.zig");

/// Durable slot-chain endpoints, physical entry count, and tombstone count.
pub fn State(
    comptime PageIdT: type,
    comptime SizeT: type,
    comptime TailT: type,
    comptime Endian: std.builtin.Endian,
) type {
    const PageChainState = page_chain.State(PageIdT, TailT, Endian);
    const PackedSize = PackedInt(SizeT, Endian);

    const StateT = extern struct {
        page_chain: PageChainState = .{},
        elements_count: PackedSize = .init(0),
        tombstone_count: PackedSize = .init(0),
    };
    comptime {
        if (@alignOf(StateT) != 1 or
            @offsetOf(StateT, "page_chain") != 0 or
            @offsetOf(StateT, "elements_count") != @sizeOf(PageChainState) or
            @offsetOf(StateT, "tombstone_count") !=
                @sizeOf(PageChainState) + @sizeOf(PackedSize) or
            @sizeOf(StateT) != @sizeOf(PageChainState) + 2 * @sizeOf(PackedSize))
        {
            @compileError("SlotChain state layout changed");
        }
    }
    return StateT;
}
