const std = @import("std");
const PackedInt = @import("../core/core.zig").packed_int.PackedInt;
const header = @import("header.zig");

pub fn LongStore(comptime PageIdT: type, comptime IndexT: type, comptime SizeT: type, comptime Endian: std.builtin.Endian) type {
    const PageIdType = PackedInt(PageIdT, Endian);
    const IndexType = PackedInt(IndexT, Endian);
    const SizeType = PackedInt(SizeT, Endian);

    const DataHeaderType = extern struct {
        size: IndexType,
        reserved: IndexType,
    };

    const HeaderType = extern struct {
        total_size: SizeType,
        last: PageIdType,
        next: PageIdType,
        data: DataHeaderType,
    };

    const ChunkType = extern struct {
        prev: PageIdType,
        next: PageIdType,
        data: DataHeaderType,
    };

    return struct {
        pub const PageHeader = HeaderType;
        pub const Chunk = ChunkType;
    };
}
