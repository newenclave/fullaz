const std = @import("std");
const PackedInt = @import("../packed_int.zig").PackedInt;
const PageViewType = @import("header.zig").View;

pub fn View(comptime PageIdT: type, comptime IndexT: type, comptime Subheader: type, comptime Endian: std.builtin.Endian, comptime read_only: bool) type {
    return struct {
        const Self = @This();
        const DataType = if (read_only) []const u8 else []u8;
        const PageView = PageViewType(PageIdT, IndexT, Endian, read_only);

        page_view: PageView,

        pub fn init(data: DataType) Self {
            return .{
                .page_view = PageView.init(data),
            };
        }

        pub fn page(self: *const Self) DataType {
            return self.page_view.page;
        }

        pub fn formatPage(self: *Self, kind: u16, page_id: PageIdT, metadata_len: IndexT) void {
            self.page_view.formatPage(kind, page_id, @as(IndexT, @intCast(@sizeOf(Subheader))), metadata_len);
        }

        pub fn subheader(self: *const Self) *const Subheader {
            const subhdr = self.page_view.subheader();
            return @ptrCast(@alignCast(&subhdr[0]));
        }

        pub fn subheaderMut(self: *Self) *Subheader {
            if (read_only) {
                @compileError("Cannot get mutable subheader from a read-only page");
            }
            const subhdr = self.page_view.subheaderMut();
            return @ptrCast(@alignCast(&subhdr[0]));
        }
    };
}
