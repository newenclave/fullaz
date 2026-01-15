const std = @import("std");
const PackedInt = @import("../packed_int.zig").PackedInt;

fn Header(comptime PageIdT: type, comptime IndexT: type, comptime Endian: std.builtin.Endian) type {
    const PageIdType = PackedInt(PageIdT, Endian);
    const IndexType = PackedInt(IndexT, Endian);
    const UInt16 = PackedInt(u16, Endian);
    const UInt32 = PackedInt(u32, Endian);

    return extern struct {
        kind: UInt16,
        subheader_size: IndexType,
        metadata_size: IndexType,
        page_end: IndexType,
        self_pid: PageIdType,
        crc: UInt32,
    };
}

pub fn View(comptime PageIdT: type, comptime IndexT: type, comptime Endian: std.builtin.Endian, comptime read_only: bool) type {
    const IndexType = PackedInt(IndexT, Endian);

    return struct {
        const Self = @This();
        pub const DataType = if (read_only) []const u8 else []u8;

        pub const PageHeader = Header(PageIdT, IndexT, Endian);

        page: DataType,
        pub fn init(page: DataType) Self {
            return .{
                .page = page,
            };
        }

        pub fn formatPage(self: *Self, kind: u16, page_id: PageIdT, subhdr_len: IndexT, metadata_len: IndexT) void {
            if (read_only) {
                @compileError("Cannot format a read-only page");
            }
            if (self.page.len < subhdr_len + metadata_len) {
                @panic("Page size is smaller than subheader + metadata size");
            }

            if (@as(usize, @intCast(IndexType.max())) < self.page.len) {
                @panic("Page size exceeds maximum representable size in IndexT");
            }

            var hdr = self.headerMut();

            hdr.kind.set(kind);
            hdr.subheader_size.set(subhdr_len);
            hdr.metadata_size.set(metadata_len);

            hdr.page_end.set(@as(IndexT, @intCast(self.page.len)));
            hdr.self_pid.set(page_id);
            hdr.crc.set(0);
        }

        pub fn header(self: *const Self) *const PageHeader {
            return @ptrCast(self.page.ptr);
        }

        pub fn headerMut(self: *Self) *PageHeader {
            if (read_only) {
                @compileError("Cannot get mutable header from a read-only page");
            }
            return @ptrCast(self.page.ptr);
        }

        pub fn subheader(self: *const Self) []const u8 {
            const hdr = self.header();
            const sh_len = @as(usize, hdr.subheader_size.get());
            const subhdr_end = @sizeOf(PageHeader) + sh_len;
            return self.page[@sizeOf(PageHeader)..subhdr_end];
        }

        pub fn subheaderMut(self: *Self) []u8 {
            if (read_only) {
                @compileError("Cannot get mutable subheader from a read-only page");
            }
            const hdr = self.headerMut();
            const subhdr_end = @sizeOf(PageHeader) + @as(usize, hdr.subheader_size.get());
            return self.page[@sizeOf(PageHeader)..subhdr_end];
        }

        pub fn metadata(self: *const Self) []const u8 {
            const hdr = self.header();
            const subhdr_end = @sizeOf(PageHeader) + @as(usize, hdr.subheader_size.get());
            const metadata_end = subhdr_end + @as(usize, hdr.metadata_size.get());
            return self.page[subhdr_end..metadata_end];
        }

        pub fn metadataMut(self: *Self) []u8 {
            if (read_only) {
                @compileError("Cannot get mutable metadata from a read-only page");
            }
            const hdr = self.headerMut();
            const subhdr_end = @sizeOf(PageHeader) + @as(usize, hdr.subheader_size.get());
            const metadata_end = subhdr_end + @as(usize, hdr.metadata_size.get());
            return self.page[subhdr_end..metadata_end];
        }

        pub fn data(self: *const Self) []const u8 {
            const all_heades_len = self.allHeadersSize();
            return self.page[all_heades_len..];
        }

        pub fn dataMut(self: *Self) []u8 {
            if (read_only) {
                @compileError("Cannot get mutable data from a read-only page");
            }
            const all_headers_len = self.allHeadersSize();
            return self.page[all_headers_len..];
        }

        pub fn pageHeaderSize() usize {
            return @sizeOf(PageHeader);
        }

        pub fn allHeadersSize(self: *const Self) usize {
            const hdr = self.header();
            return @sizeOf(PageHeader) + @as(usize, hdr.subheader_size.get()) + @as(usize, hdr.metadata_size.get());
        }
    };
}
