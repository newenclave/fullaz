const std = @import("std");
const PackedInt = @import("../core/core.zig").packed_int.PackedInt;
const header = @import("header.zig");
const PageSlotRef = @import("page_slot_ref.zig").PageSlotRef;

pub fn SkipList(comptime PageIdT: type, comptime IndexT: type, comptime Endian: std.builtin.Endian) type {
    const PageIdType = PackedInt(PageIdT, Endian);
    const IndexType = PackedInt(IndexT, Endian);

    _ = PageIdType;

    const SkipListNodeIdType = PageSlotRef(PageIdT, IndexT, Endian);

    const SkipListNodeSubheaderType = extern struct {
        const Self = @This();

        next: SkipListNodeIdType,
        prev: SkipListNodeIdType,

        key_len: IndexType,
        value_len: IndexType,
        level: u8,

        pub fn formatHeader(self: *Self) void {
            self.next.format();
            self.prev.format();
        }
    };

    return struct {
        pub const SkipListSubheader = SkipListNodeSubheaderType;
    };
}
