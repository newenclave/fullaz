const std = @import("std");
const PackedInt = @import("../core/core.zig").packed_int.PackedInt;
const header = @import("header.zig");

pub fn SlabAllocator(comptime PageIdT: type, comptime IndexT: type, comptime SizeClassT: type, comptime Endian: std.builtin.Endian) type {
    const PageIdType = PackedInt(PageIdT, Endian);
    const IndexType = PackedInt(IndexT, Endian);
    const SizeClassType = PackedInt(SizeClassT, Endian);

    const SubHeaderImpl = extern struct {
        size_class: SizeClassType,
    };

    return struct {
        pub const PageId = PageIdType;
        pub const Index = IndexType;
        pub const SizeClass = SizeClassType;
        pub const PageHeader = header.Header(PageIdT, IndexT, Endian);
        pub const SubHeader = SubHeaderImpl;
    };
}
