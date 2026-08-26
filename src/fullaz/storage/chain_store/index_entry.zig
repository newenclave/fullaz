const std = @import("std");
const PackedInt = @import("../../core/packed_int.zig").PackedInt;

pub fn IndexEntry(comptime PageIdT: type, comptime SizeT: type, comptime Endian: std.builtin.Endian) type {
    return extern struct {
        const PageId = PackedInt(PageIdT, Endian);
        const Size = PackedInt(SizeT, Endian);
        page_id: PageId,
        size: Size,
    };
}
