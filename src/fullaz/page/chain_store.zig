const std = @import("std");
const PackedInt = @import("../core/core.zig").packed_int.PackedInt;
const header = @import("header.zig");

// This is almost identical to LongStore, but kept separate for clarity and potential future divergence.
pub fn ChainStore(comptime PageIdT: type, comptime IndexT: type, comptime SizeT: type, comptime Endian: std.builtin.Endian) type {
    const PageIdType = PackedInt(PageIdT, Endian);
    const IndexType = PackedInt(IndexT, Endian);
    const SizeType = PackedInt(SizeT, Endian);
    _ = SizeType; // Currently unused, but reserved for potential future use.

    const PayloadHeaderType = extern struct {
        size: IndexType,
        reserved: IndexType,
    };

    const LinkHeaderType = extern struct {
        back: PageIdType,
        fwd: PageIdType,
        payload: PayloadHeaderType,
    };

    const ChunkType = extern struct {
        link: LinkHeaderType,
        flags: IndexType,
    };

    return struct {
        pub const ChunkSubheader = ChunkType;
        pub const LinkHeader = LinkHeaderType;
    };
}
