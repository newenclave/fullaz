const std = @import("std");
const header = @import("header.zig");
const core = @import("../core/core.zig");
const links = @import("links.zig");
const SubheaderView = @import("subheader.zig").View;
const PackedInt = core.packed_int.PackedInt;

pub fn RadixTree(comptime PageIdT: type, comptime IndexT: type, comptime KeyT: type, comptime Endian: std.builtin.Endian) type {
    const PackedPageId = PackedInt(PageIdT, Endian);
    const KeyType = PackedInt(KeyT, Endian);
    const LevelType = PackedInt(u8, Endian);
    const ParentIdxType = PackedInt(u16, Endian);
    const FreeLeafLinks = links.Trait(PageIdT, Endian);
    _ = IndexT; // Currently not used, but can be used for future extensions (e.g., metadata length in header)

    const LeafSubheaderType = extern struct {
        const Self = @This();
        parent: PackedPageId,
        parent_quotient: KeyType,
        parent_idx: ParentIdxType,
        on_free_list: u8,
        free_leaf_links: FreeLeafLinks.Storage,
        pub fn formatHeader(self: *Self) void {
            self.parent.setMax();
            self.parent_quotient.set(0);
            self.parent_idx.set(0);
            self.on_free_list = 0;
            FreeLeafLinks.format(&self.free_leaf_links);
        }
    };

    const InodeSubheaderType = extern struct {
        const Self = @This();
        parent: PackedPageId,
        parent_quotient: KeyType,
        parent_idx: ParentIdxType,
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
        child: PackedPageId,
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
