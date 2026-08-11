const std = @import("std");
const header = @import("header.zig");
const core = @import("../core/core.zig");
const SubheaderView = @import("subheader.zig").View;
const PackedInt = core.packed_int.PackedInt;

pub fn WeightedBpt(comptime PageIdT: type, comptime IndexT: type, comptime WeightT: type, comptime Endian: std.builtin.Endian) type {
    const PackedPageId = PackedInt(PageIdT, Endian);
    const IndexType = PackedInt(IndexT, Endian);
    const WeightType = PackedInt(WeightT, Endian);

    _ = IndexType;

    const LeafSubheaderType = extern struct {
        const Self = @This();
        parent: PackedPageId,
        prev: PackedPageId,
        next: PackedPageId,
        weight: WeightType,
        pub fn formatHeader(self: *Self) void {
            self.parent.setMax();
            self.prev.setMax();
            self.next.setMax();
            self.weight.set(0);
        }
    };

    const LeafSlotHeaderType = extern struct {
        weight: WeightType,
    };

    const InodeSubheaderType = extern struct {
        const Self = @This();
        parent: PackedPageId,
        total_weight: WeightType,
        pub fn formatHeader(self: *Self) void {
            self.parent.setMax();
            self.total_weight.set(0);
        }
    };

    const InodeSlotType = extern struct {
        child: PackedPageId,
        weight: WeightType,
    };

    return struct {
        pub const LeafSubheader = LeafSubheaderType;
        pub const InodeSubheader = InodeSubheaderType;

        pub const InodeSlot = InodeSlotType;
        pub const LeafSlotHeader = LeafSlotHeaderType;
    };
}
