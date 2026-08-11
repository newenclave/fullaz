const std = @import("std");
const header = @import("header.zig");
const core = @import("../core/core.zig");
const SubheaderView = @import("subheader.zig").View;
const PackedInt = core.packed_int.PackedInt;

pub fn Bpt(comptime PageIdT: type, comptime IndexT: type, comptime Endian: std.builtin.Endian) type {
    const PackedPageId = PackedInt(PageIdT, Endian);
    const IndexType = PackedInt(IndexT, Endian);

    const LeafSubheaderType = extern struct {
        const Self = @This();
        parent: PackedPageId,
        prev: PackedPageId,
        next: PackedPageId,
        pub fn formatHeader(self: *Self) void {
            self.parent.setMax();
            self.prev.setMax();
            self.next.setMax();
        }
    };

    const LeafSlotHeaderType = extern struct {
        key_size: IndexType,
    };

    const InodeSubheaderType = extern struct {
        parent: PackedPageId,
        rightmost_child: PackedPageId,
    };

    const InodeSlotHeaderType = extern struct {
        child: PackedPageId,
    };

    return struct {
        pub const LeafSubheader = LeafSubheaderType;
        pub const InodeSubheader = InodeSubheaderType;

        pub const InodeSlotHeader = InodeSlotHeaderType;
        pub const LeafSlotHeader = LeafSlotHeaderType;
    };
}
