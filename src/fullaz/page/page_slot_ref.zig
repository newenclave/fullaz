const std = @import("std");
const PackedInt = @import("../core/core.zig").packed_int.PackedInt;

pub fn PageSlotRef(comptime PageIdT: type, comptime SlotIdT: type, comptime Endian: std.builtin.Endian) type {
    return extern struct {
        pub const PageIdType = PackedInt(PageIdT, Endian);
        pub const SlotIdType = PackedInt(SlotIdT, Endian);

        const Self = @This();
        page_id: PageIdType,
        slot_id: SlotIdType,
        pub fn format(self: *Self) void {
            self.page_id.setMax();
            self.slot_id.setMax();
        }
    };
}
