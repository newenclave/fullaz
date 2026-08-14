const std = @import("std");
const PackedInt = @import("../core/core.zig").packed_int.PackedInt;

pub fn Fsm(comptime PageIdT: type, comptime IndexT: type, comptime SizeClassT: type, comptime Endian: std.builtin.Endian) type {
    const PackedPageId = PackedInt(PageIdT, Endian);
    const IndexType = PackedInt(IndexT, Endian);
    const SizeClassType = PackedInt(SizeClassT, Endian);

    const SubheaderImpl = extern struct {
        size_class: SizeClassType,
    };

    const SlotImpl = extern struct {
        const Self = @This();
        pid: PackedPageId,
        free_space: IndexType,
        pub fn format(self: *Self) void {
            self.pid.setMax();
            self.free_space.setMax();
        }
    };

    return struct {
        pub const Subheader = SubheaderImpl;
        pub const Slot = SlotImpl;
    };
}
