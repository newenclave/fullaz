const std = @import("std");
const PackedInt = @import("../core/core.zig").packed_int.PackedInt;
const header = @import("header.zig");
const PageSlotRef = @import("page_slot_ref.zig").PageSlotRef;

pub fn SkipList(comptime PageIdT: type, comptime IndexT: type, comptime Endian: std.builtin.Endian) type {
    const layout = struct {
        const PackedIndex = PackedInt(IndexT, Endian);
        const PackedPageId = PackedInt(PageIdT, Endian);
        const SkipListNodeIdType = PageSlotRef(PageIdT, IndexT, Endian);
    };

    const SkipListNodeSubheaderType = extern struct {
        const Self = @This();
        reserved: [16]u8, // Reserved for future use, must be zero

        pub fn formatHeader(self: *Self) void {
            @memset(&self.reserved, 0);
        }
    };

    const LevelRefType = extern struct {
        const Self = @This();
        next: layout.SkipListNodeIdType,
        prev: layout.SkipListNodeIdType,
        pub fn format(self: *Self) void {
            self.next.format();
            self.prev.format();
        }
    };

    const SkipListNodeType = extern struct {
        const Self = @This();

        level: u8,
        reserved: [3]u8,

        key_len: layout.PackedIndex,
        value_len: layout.PackedIndex, // todo: do we need this value?

        pub fn formatHeader(self: *Self) void {
            self.reserved = [3]u8{0} ** 3;
        }
    };

    return struct {
        pub const PackedPageId = layout.PackedPageId;
        pub const PackedIndex = layout.PackedIndex;
        pub const SkipListSubheader = SkipListNodeSubheaderType;
        pub const SkipListNode = SkipListNodeType;
        pub const LevelRef = LevelRefType;
    };
}
