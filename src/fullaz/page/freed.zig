const std = @import("std");
const PackedInt = @import("../core/packed_int.zig").PackedInt;

pub fn Freed(comptime PageIdT: type, comptime Endian: std.builtin.Endian) type {
    const PageIdType = PackedInt(PageIdT, Endian);
    const UInt16 = PackedInt(u16, Endian);
    const UInt32 = PackedInt(u32, Endian);

    return extern struct {
        kind: UInt16,
        next: PageIdType,
        crc: UInt32,
    };
}

pub fn View(comptime PageIdT: type, comptime Endian: std.builtin.Endian, comptime read_only: bool) type {
    return struct {
        const Self = @This();
        const DataType = if (read_only) []const u8 else []u8;

        pub const FreedHeader = Freed(PageIdT, Endian);

        page: DataType,
        pub fn init(page: DataType) Self {
            return .{
                .page = page,
            };
        }

        pub fn formatPage(self: *Self, next_page_id: PageIdT) void {
            if (read_only) {
                @compileError("Cannot format a read-only page");
            }
            if (self.page.len < @sizeOf(FreedHeader)) {
                @panic("Page size is smaller than Freed header size");
            }

            var hdr = self.headerMut();

            hdr.kind.set(@TypeOf(hdr.kind).max());
            hdr.next.set(next_page_id);
            hdr.crc.set(0);
        }

        pub fn header(self: *const Self) *const FreedHeader {
            return @ptrCast(self.page.ptr);
        }

        pub fn headerMut(self: *Self) *FreedHeader {
            if (read_only) {
                @compileError("Cannot get mutable header from a read-only page");
            }
            return @ptrCast(self.page.ptr);
        }
    };
}
