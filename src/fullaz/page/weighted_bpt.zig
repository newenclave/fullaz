const std = @import("std");
const header = @import("header.zig");
const core = @import("../core/core.zig");
const SubheaderView = @import("subheader.zig").View;
const PackedInt = core.packed_int.PackedInt;

pub fn WeightedBpt(comptime PageIdT: type, comptime IndexT: type, comptime WeightT: type, comptime Endian: std.builtin.Endian) type {
    const PageIdType = PackedInt(PageIdT, Endian);
    const IndexType = PackedInt(IndexT, Endian);
    const WeightType = PackedInt(WeightT, Endian);

    const LeafSubheaderType = extern struct {
        const Self = @This();
        parent: PageIdType,
        prev: PageIdType,
        next: PageIdType,
        weight: WeightType,
        pub fn formatHeader(self: *Self) void {
            self.parent.setMax();
            self.prev.setMax();
            self.next.setMax();
            self.weight.set(0);
        }
    };

    const LeafSlotHeaderType = extern struct {
        weight: IndexType,
    };

    const InodeSubheaderType = extern struct {
        parent: PageIdType,
        total_weight: WeightType,
    };

    const InodeSlotType = extern struct {
        child: PageIdType,
        weight: WeightType,
    };

    return struct {
        pub const LeafSubheader = LeafSubheaderType;
        pub const InodeSubheader = InodeSubheaderType;

        pub const InodeSlot = InodeSlotType;
        pub const LeafSlotHeader = LeafSlotHeaderType;
    };
}
