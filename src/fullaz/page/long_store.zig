const std = @import("std");
const PackedInt = @import("../core/core.zig").packed_int.PackedInt;
const header = @import("header.zig");

pub fn LongStore(comptime PageIdT: type, comptime IndexT: type, comptime SizeT: type, comptime Endian: std.builtin.Endian) type {
    const PageIdType = PackedInt(PageIdT, Endian);
    const IndexType = PackedInt(IndexT, Endian);
    const SizeType = PackedInt(SizeT, Endian);

    const ChunkFlagsValues = enum(IndexT) {
        first = 1 << 0,
        last = 1 << 1,
    };

    const DataHeaderType = extern struct {
        size: IndexType,
        reserved: IndexType,
    };

    const CommonHeaderType = extern struct {
        next: PageIdType,
        data: DataHeaderType,
    };

    const HeaderType = extern struct {
        total_size: SizeType,
        last: PageIdType,
        common: CommonHeaderType,
    };

    const ChunkType = extern struct {
        flags: IndexType,
        prev: PageIdType,
        common: CommonHeaderType,
    };

    return struct {
        pub const HeaderSubheader = HeaderType;
        pub const ChunkSubheader = ChunkType;
        pub const ChunkFlags = ChunkFlagsValues;
    };
}
