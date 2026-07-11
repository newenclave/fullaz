const std = @import("std");
const core = @import("../core/core.zig");
const PackedInt = core.packed_int.PackedInt;

pub fn Rtree(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime CoordT: type,
    comptime dims: usize,
    comptime Endian: std.builtin.Endian,
) type {
    const PageIdType = PackedInt(PageIdT, Endian);
    const IndexType = PackedInt(IndexT, Endian);
    const CoordType = PackedInt(CoordT, Endian);

    const MbrType = extern struct {
        low: [dims]CoordType,
        high: [dims]CoordType,
    };

    const LeafSubheaderType = extern struct {
        const Self = @This();
        parent: PageIdType,
        pub fn formatHeader(self: *Self) void {
            self.parent.setMax();
        }
    };

    const LeafSlotHeaderType = extern struct {
        mbr: MbrType,
    };

    const InodeSubheaderType = extern struct {
        const Self = @This();
        parent: PageIdType,
        level: IndexType,
        pub fn formatHeader(self: *Self) void {
            self.parent.setMax();
            self.level.set(0);
        }
    };

    const InodeSlotHeaderType = extern struct {
        child: PageIdType,
        mbr: MbrType,
    };

    return struct {
        pub const Mbr = MbrType;
        pub const Coord = CoordType;
        pub const dimensions = dims;

        pub const LeafSubheader = LeafSubheaderType;
        pub const InodeSubheader = InodeSubheaderType;

        pub const LeafSlotHeader = LeafSlotHeaderType;
        pub const InodeSlotHeader = InodeSlotHeaderType;
    };
}
