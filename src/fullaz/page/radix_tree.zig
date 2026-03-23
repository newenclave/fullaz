const std = @import("std");
const header = @import("header.zig");
const core = @import("../core/core.zig");
const SubheaderView = @import("subheader.zig").View;
const PackedInt = core.packed_int.PackedInt;

pub fn RadixTree(comptime PageIdT: type, comptime IndexT: type, comptime KeyT: type, comptime Endian: std.builtin.Endian) type {
    const PageIdType = PackedInt(PageIdT, Endian);
    const KeyType = PackedInt(KeyT, Endian);
    const LevelType = PackedInt(u8, Endian);
    const IndexType = PackedInt(IndexT, Endian);

    const LeafSubheaderType = extern struct {
        const Self = @This();
        parent: PageIdType,
        parent_quotient: KeyType,
        parent_idx: KeyType,
        slot_size: IndexType,
        pub fn formatHeader(self: *Self) void {
            self.parent.setMax();
            self.parent_quotient.set(0);
            self.parent_idx.set(0);
            self.slot_size.set(0);
        }
    };

    const InodeSubheaderType = extern struct {
        const Self = @This();
        parent: PageIdType,
        parent_quotient: KeyType,
        parent_idx: KeyType,
        level: LevelType,
        pub fn formatHeader(self: *Self) void {
            self.parent.setMax();
            self.parent_quotient.set(0);
            self.parent_idx.set(0);
            self.level.set(0);
        }
    };

    const InodeSlotType = extern struct {
        const Self = @This();
        child: PageIdType,
        pub fn formatSlot(self: *Self) void {
            self.child.setMax();
        }
    };

    return struct {
        pub const LeafSubheader = LeafSubheaderType;
        pub const InodeSubheader = InodeSubheaderType;

        pub const InodeSlot = InodeSlotType;
    };
}
