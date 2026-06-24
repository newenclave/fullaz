const std = @import("std");

pub fn SlotInfo(comptime PageIdT: type, comptime IndexT: type) type {
    return struct {
        pid: PageIdT,
        free_space: IndexT,
        slot_id: usize,
    };
}
