const std = @import("std");
const headers = @import("../../page/long_store.zig");
const PageView = @import("../../page/header.zig").View;
const errors = @import("../../core/errors.zig");

const conracts = @import("../../contracts/contracts.zig");

pub fn View(comptime PageIdT: type, comptime IndexT: type, comptime SizeT: type, comptime Endian: std.builtin.Endian, comptime read_only: bool) type {
    const SubheadersType = headers.LongStore(PageIdT, IndexT, SizeT, Endian);
    const DataType = if (read_only) []const u8 else []u8;

    const HeaderPageView = PageView(PageIdT, IndexT, Endian, read_only);

    const CommonErrorSet = errors.SpaceError;

    const HeaderViewImpl = struct {
        const Self = @This();
        pub const SubheaderType = SubheadersType.PageHeader;
        pub const HeaderType = HeaderPageView.PageHeader;

        pub const Error = error{} ||
            CommonErrorSet;

        page_view: HeaderPageView = undefined,
        fn init(data: DataType) Self {
            return Self{
                .page_view = HeaderPageView.init(data),
            };
        }

        pub fn formatPage(self: *Self, kind: u16, page_id: PageIdT, metadata_len: IndexT) void {
            if (read_only) {
                @compileError("Cannot format a read-only page");
            }
            self.page_view.formatPage(kind, page_id, @sizeOf(SubheaderType), metadata_len);
            var sh = self.subheaderMut();
            sh.total_size.set(0);
            sh.last.set(@TypeOf(sh.last).max());
            sh.next.set(@TypeOf(sh.next).max());
            sh.data.size.set(0);
            sh.data.reserved.set(0);
        }

        pub fn subheader(self: *const Self) *const SubheaderType {
            const sh_ptr = self.page_view.subheader().ptr;
            return @ptrCast(sh_ptr);
        }

        pub fn subheaderMut(self: *Self) *SubheaderType {
            if (read_only) {
                @compileError("Cannot get mutable subheader from a read-only page");
            }
            const sh_ptr = self.page_view.subheader().ptr;
            return @ptrCast(sh_ptr);
        }
    };

    const ChunkViewImpl = struct {
        const Self = @This();
        pub const SubheaderType = SubheadersType.Chunk;
        pub const HeaderType = HeaderPageView.PageHeader;

        pub const Error = error{} ||
            CommonErrorSet;

        page_view: HeaderPageView = undefined,
        fn init(data: DataType) Self {
            return Self{
                .page_view = HeaderPageView.init(data),
            };
        }

        pub fn formatPage(self: *Self, kind: u16, page_id: PageIdT, metadata_len: IndexT) void {
            if (read_only) {
                @compileError("Cannot format a read-only page");
            }
            self.page_view.formatPage(kind, page_id, @sizeOf(SubheaderType), metadata_len);
            var sh = self.subheaderMut();
            sh.prev.set(@TypeOf(sh.prev).max());
            sh.next.set(@TypeOf(sh.next).max());
            sh.data.size.set(0);
            sh.data.reserved.set(0);
        }

        pub fn subheader(self: *const Self) *const SubheaderType {
            const sh_ptr = self.page_view.subheader().ptr;
            return @ptrCast(sh_ptr);
        }
        pub fn subheaderMut(self: *Self) *SubheaderType {
            if (read_only) {
                @compileError("Cannot get mutable subheader from a read-only page");
            }
            const sh_ptr = self.page_view.subheader().ptr;
            return @ptrCast(sh_ptr);
        }
    };

    return struct {
        const HeaderView = HeaderViewImpl;
        const ChunkView = ChunkViewImpl;
    };
}
