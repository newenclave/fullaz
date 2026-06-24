const std = @import("std");
const PackedInt = @import("../core/core.zig").packed_int.PackedInt;
const header = @import("header.zig");

pub fn Fsm(comptime PageIdT: type, comptime IndexT: type, comptime SizeClassT: type, comptime Endian: std.builtin.Endian) type {
    const PageIdType = PackedInt(PageIdT, Endian);
    const IndexType = PackedInt(IndexT, Endian);
    const SizeClassType = PackedInt(SizeClassT, Endian);

    const SubheaderImpl = extern struct {
        const Self = @This();
        size_class: SizeClassType,
        prev: PageIdType,
        next: PageIdType,

        pub fn formatHeader(self: *Self) void {
            self.prev.setMax();
            self.next.setMax();
        }
    };

    const SlotImpl = extern struct {
        const Self = @This();
        pid: PageIdType,
        free_space: IndexType,
        pub fn format(self: *Self) void {
            self.pid.setMax();
            self.free_space.setMax();
        }
    };

    return struct {
        pub const PageHeader = header.Header(PageIdT, IndexT, Endian);
        pub const Subheader = SubheaderImpl;
        pub const Slot = SlotImpl;
    };
}
