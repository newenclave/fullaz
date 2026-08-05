const std = @import("std");
const PackedInt = @import("../core/packed_int.zig").PackedInt;
const PageViewType = @import("header.zig").ViewImpl;

pub fn View(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime Subheader: type,
    comptime Endian: std.builtin.Endian,
    comptime read_only: bool,
) type {
    return ViewImpl(
        PageIdT,
        IndexT,
        Subheader,
        void,
        Endian,
        read_only,
    );
}

pub fn ViewImpl(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime AdditionalT: type,
    comptime Subheader: type,
    comptime Endian: std.builtin.Endian,
    comptime read_only: bool,
) type {
    return struct {
        const Self = @This();
        const DataType = if (read_only) []const u8 else []u8;

        pub const PageView = PageViewType(
            PageIdT,
            IndexT,
            AdditionalT,
            Endian,
            read_only,
        );

        page_view: PageView,

        pub fn init(data: DataType) Self {
            return .{
                .page_view = PageView.init(data),
            };
        }

        pub fn page(self: *const Self) PageView {
            return self.page_view;
        }

        pub fn pageMut(self: *Self) PageView {
            if (read_only) {
                @compileError("Cannot get mutable page from a read-only view");
            }
            return self.page_view;
        }

        pub fn formatPage(self: *Self, kind: u16, page_id: PageIdT, metadata_len: IndexT) void {
            self.page_view.formatPage(
                kind,
                page_id,
                @as(IndexT, @intCast(@sizeOf(Subheader))),
                metadata_len,
            );
        }

        pub fn header(self: *const Self) *const PageView.PageHeader {
            return self.page_view.header();
        }

        pub fn headerMut(self: *Self) *PageView.PageHeader {
            if (read_only) {
                @compileError("Cannot get mutable header from a read-only page");
            }
            return self.page_view.headerMut();
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
