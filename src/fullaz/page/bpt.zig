const std = @import("std");
const header = @import("header.zig");
const core = @import("../core/core.zig");
const SubheaderView = @import("subheader.zig").View;
const PackedInt = core.packed_int.PackedInt;
const slots = @import("../slots/slots.zig");
const algorithm = core.algorithm;
const errors = core.errors;

pub fn Bpt(comptime PageIdT: type, comptime IndexT: type, comptime Endian: std.builtin.Endian) type {
    const PageIdType = PackedInt(PageIdT, Endian);
    const IndexType = PackedInt(IndexT, Endian);

    const LeafSubheaderType = extern struct {
        const Self = @This();
        parent: PageIdType,
        prev: PageIdType,
        next: PageIdType,
        pub fn formatHeader(self: *Self) void {
            self.parent.set(@TypeOf(self.parent).max());
            self.prev.set(@TypeOf(self.prev).max());
            self.next.set(@TypeOf(self.next).max());
        }
    };

    const LeafSlotHeaderType = extern struct {
        key_size: IndexType,
    };

    const InodeSubheaderType = extern struct {
        parent: PageIdType,
        rightmost_child: PageIdType,
    };

    const InodeSlotHeaderType = extern struct {
        child: PageIdType,
    };

    return struct {
        pub const LeafSubheader = LeafSubheaderType;
        pub const InodeSubheader = InodeSubheaderType;

        pub const InodeSlotHeader = InodeSlotHeaderType;
        pub const LeafSlotHeader = LeafSlotHeaderType;
    };
}
