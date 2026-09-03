const std = @import("std");
const PackedInt = @import("../../core/packed_int.zig").PackedInt;
const wbpt = @import("../../weighted_bpt/weighted_bpt.zig");

/// Durable state required to reopen one chain store.
pub fn State(
    comptime PageIdT: type,
    comptime SizeT: type,
    comptime Endian: std.builtin.Endian,
) type {
    const PackedPageId = PackedInt(PageIdT, Endian);
    const PackedSize = PackedInt(SizeT, Endian);

    return extern struct {
        first: PackedPageId = PackedPageId.init(PackedPageId.max),
        last: PackedPageId = PackedPageId.init(PackedPageId.max),
        total_size: PackedSize = PackedSize.init(0),
    };
}

/// Durable state for a chain store with a weighted chunk index.
pub fn WeightedState(
    comptime PageIdT: type,
    comptime SizeT: type,
    comptime Endian: std.builtin.Endian,
) type {
    return extern struct {
        chain: State(PageIdT, SizeT, Endian) = .{},
        index: wbpt.models.paged.State(PageIdT) = .{},
    };
}
