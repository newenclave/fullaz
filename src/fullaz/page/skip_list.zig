const std = @import("std");
const PackedInt = @import("../core/core.zig").packed_int.PackedInt;
const header = @import("header.zig");
const PageSlotRef = @import("page_slot_ref.zig").PageSlotRef;

pub fn SkipList(comptime PageIdT: type, comptime IndexT: type, comptime Endian: std.builtin.Endian) type {
    const PageIdPackedType = PackedInt(PageIdT, Endian);
    const IndexPackedType = PackedInt(IndexT, Endian);

    const SkipListNodeIdType = PageSlotRef(PageIdT, IndexT, Endian);

    const SkipListNodeSubheaderType = extern struct {
        const Self = @This();
        reserver: [16]u8, // Reserved for future use, must be zero

        pub fn formatHeader(self: *Self) void {
            @memset(&self.reserver, 0);
        }
    };

    const LevelRefType = extern struct {
        const Self = @This();
        next: SkipListNodeIdType,
        prev: SkipListNodeIdType,
        pub fn format(self: *Self) void {
            self.next.format();
            self.prev.format();
        }
    };

    const SkipListNodeType = extern struct {
        const Self = @This();

        key_len: IndexPackedType,
        value_len: IndexPackedType,
        level: u8,
        reserver: [3]u8,

        pub fn formatHeader(self: *Self) void {
            self.next.format();
            self.prev.format();
        }
    };

    return struct {
        pub const PageIdType = PageIdPackedType;
        pub const IndexType = IndexPackedType;
        pub const SkipListSubheader = SkipListNodeSubheaderType;
        pub const SkipListNode = SkipListNodeType;
        pub const LevelRef = LevelRefType;
    };
}
