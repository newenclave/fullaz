const std = @import("std");
const SkipListSubheader = @import("../../../page/skip_list.zig").SkipListSubheader;

pub fn View(comptime PageIdT: type, comptime IndexT: type, comptime Endian: std.builtin.Endian, comptime read_only: bool) type {
    _ = SkipListSubheader(PageIdT, IndexT, Endian);
    _ = read_only;
    return struct {
        const Self = @This();
    };
}
