const std = @import("std");
const PackedInt = @import("../../core/packed_int.zig").PackedInt;

/// Durable page-chain endpoints. Use `void` for `TailT` when only the root is
/// stored, or `PageIdT` when the tail is stored as well.
pub fn State(
    comptime PageIdT: type,
    comptime TailT: type,
    comptime Endian: std.builtin.Endian,
) type {
    comptime assertTailType(PageIdT, TailT);
    const PackedPageId = PackedInt(PageIdT, Endian);

    return if (TailT == void) extern struct {
        first: PackedPageId = .init(std.math.maxInt(PageIdT)),
    } else extern struct {
        first: PackedPageId = .init(std.math.maxInt(PageIdT)),
        last: PackedPageId = .init(std.math.maxInt(PageIdT)),
    };
}

pub fn hasTail(comptime PageIdT: type, comptime TailT: type) bool {
    comptime assertTailType(PageIdT, TailT);
    return TailT != void;
}

fn assertTailType(comptime PageIdT: type, comptime TailT: type) void {
    if (TailT != void and TailT != PageIdT) {
        @compileError("PageChain Tail must be void or match PageId");
    }
}
