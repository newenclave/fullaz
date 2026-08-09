const std = @import("std");
const core = @import("../core/core.zig");
const PackedInt = core.packed_int.PackedInt;
const PackedNumber = core.packed_int.PackedNumber;

pub fn Orthtree(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime CoordT: type,
    comptime dims: usize,
    comptime Endian: std.builtin.Endian,
) type {
    comptime {
        if (dims == 0) {
            @compileError("Orthtree requires at least one dimension");
        }
        if (dims >= @bitSizeOf(usize)) {
            @compileError("Orthtree dimension exceeds addressable child count");
        }
    }

    const child_count = 1 << dims;
    const PageIdType = PackedInt(PageIdT, Endian);
    const IndexType = PackedInt(IndexT, Endian);
    const EntryCountType = PackedInt(u32, Endian);
    const CoordType = PackedNumber(CoordT, Endian);

    const MbrType = extern struct {
        low: [dims]CoordType,
        high: [dims]CoordType,
    };

    const NodeFlagsType = struct {
        pub const internal: u8 = 1 << 0;
    };

    const NodeSubheaderType = extern struct {
        const Self = @This();

        parent: PageIdType,
        entries_first: PageIdType,
        entries_last: PageIdType,
        entries_count: EntryCountType,
        level: u8,
        flags: u8,
        reserved: [2]u8,
        bounds: MbrType,
        children: [child_count]PageIdType,

        pub fn formatHeader(self: *Self) void {
            self.parent.setMax();
            self.entries_first.setMax();
            self.entries_last.setMax();
            self.entries_count.set(0);
            self.level = 0;
            self.flags = 0;
            self.reserved = .{0} ** 2;
            inline for (0..dims) |axis| {
                self.bounds.low[axis].set(0);
                self.bounds.high[axis].set(0);
            }
            inline for (0..child_count) |index| {
                self.children[index].setMax();
            }
        }
    };

    // Value bytes trail this fixed bounding-box prefix in a slot-chain entry.
    const EntrySlotHeaderType = extern struct {
        bounds: MbrType,
    };

    return struct {
        pub const PageId = PageIdType;
        pub const Index = IndexType;
        pub const EntryCount = EntryCountType;
        pub const Coord = CoordType;
        pub const dimensions = dims;
        pub const children_per_node = child_count;

        pub const Mbr = MbrType;
        pub const NodeFlags = NodeFlagsType;
        pub const NodeSubheader = NodeSubheaderType;
        pub const EntrySlotHeader = EntrySlotHeaderType;
    };
}
