const std = @import("std");
const PackedInt = @import("../core/packed_int.zig").PackedInt;

pub fn Header(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime Endian: std.builtin.Endian,
) type {
    return HeaderImpl(
        PageIdT,
        IndexT,
        u8,
        u8,
        void,
        Endian,
    );
}

pub fn HeaderImpl(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime HeaderSizeT: type,
    comptime VersionT: type,
    comptime Additional: type,
    comptime Endian: std.builtin.Endian,
) type {
    const PageIdType = PackedInt(PageIdT, Endian);
    const IndexType = PackedInt(IndexT, Endian);
    const UInt16 = PackedInt(u16, Endian);
    const UInt32 = PackedInt(u32, Endian);
    const Version = PackedInt(VersionT, Endian);
    const HeaderSize = PackedInt(HeaderSizeT, Endian);

    const has_additional_v = Additional != void;

    comptime {
        if (has_additional_v and @alignOf(Additional) != 1) {
            @compileError("Page header Additional must have alignment 1");
        }
    }

    return extern struct {
        pub const has_additional = has_additional_v;
        pub const common_size = @offsetOf(@This(), "additional");
        kind: UInt16,
        version: Version,
        header_size: HeaderSize,
        subheader_size: IndexType,
        metadata_size: IndexType,
        page_end: IndexType,
        self_pid: PageIdType,
        crc: UInt32,
        additional: Additional = if (has_additional_v) undefined else {},
    };
}

pub fn View(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime Endian: std.builtin.Endian,
    comptime read_only: bool,
) type {
    return ViewImpl(
        PageIdT,
        IndexT,
        void,
        Endian,
        read_only,
    );
}

pub fn ViewImpl(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime AdditionalT: type,
    comptime Endian: std.builtin.Endian,
    comptime read_only: bool,
) type {
    const IndexType = PackedInt(IndexT, Endian);

    return struct {
        const Self = @This();
        pub const DataType = if (read_only) []const u8 else []u8;

        pub const Additional = AdditionalT;
        pub const PageHeader = HeaderImpl(
            PageIdT,
            IndexT,
            u8,
            u8,
            AdditionalT,
            Endian,
        );
        pub const has_additional = PageHeader.has_additional;

        pub const common_size = PageHeader.common_size;
        pub const header_size = @sizeOf(PageHeader);

        comptime {
            if (@sizeOf(PageHeader) > std.math.maxInt(u8)) {
                @compileError("Page header exceeds u8 header_size capacity");
            }
        }

        page: DataType,
        pub fn init(page: DataType) Self {
            return .{
                .page = page,
            };
        }

        pub fn formatPage(
            self: *Self,
            kind: u16,
            page_id: PageIdT,
            subhdr_len: IndexT,
            metadata_len: IndexT,
        ) void {
            if (read_only) {
                @compileError("Cannot format a read-only page");
            }
            if (self.page.len < (header_size + subhdr_len + metadata_len)) {
                @panic("Page size is smaller than subheader + metadata size");
            }

            if (@as(usize, @intCast(IndexType.max)) < self.page.len) {
                @panic("Page size exceeds maximum representable size in IndexT");
            }

            var hdr = self.headerMut();

            hdr.version.set(@intCast(1));
            hdr.header_size.set(@intCast(header_size));

            hdr.kind.set(kind);
            hdr.subheader_size.set(subhdr_len);
            hdr.metadata_size.set(metadata_len);

            hdr.page_end.set(@as(IndexT, @intCast(self.page.len)));
            hdr.self_pid.set(page_id);

            hdr.crc.set(0);
        }

        pub fn commonHeaderSize(self: *const Self) usize {
            _ = self;
            return @as(usize, PageHeader.common_size);
        }

        pub fn headerSize(self: *const Self) u8 {
            return self.header().header_size.get();
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

        pub fn additional(self: *const Self) *const Additional {
            const hdr = self.header();
            return &hdr.additional;
        }

        pub fn additionalMut(self: *Self) *Additional {
            const hdr = self.headerMut();
            return &hdr.additional;
        }

        pub fn subheader(self: *const Self) []const u8 {
            const hdr = self.header();
            const hdr_size = hdr.header_size.get();
            const sh_len = @as(usize, hdr.subheader_size.get());
            const subhdr_end = hdr_size + sh_len;
            return self.page[hdr_size..subhdr_end];
        }

        pub fn subheaderMut(self: *Self) []u8 {
            if (read_only) {
                @compileError("Cannot get mutable subheader from a read-only page");
            }
            const hdr = self.headerMut();
            const hdr_size = hdr.header_size.get();
            const subhdr_end = hdr_size + @as(usize, hdr.subheader_size.get());
            return self.page[hdr_size..subhdr_end];
        }

        pub fn metadata(self: *const Self) []const u8 {
            const hdr = self.header();
            const hdr_size = hdr.header_size.get();
            const subhdr_end = hdr_size + @as(usize, hdr.subheader_size.get());
            const metadata_end = subhdr_end + @as(usize, hdr.metadata_size.get());
            return self.page[subhdr_end..metadata_end];
        }

        pub fn metadataMut(self: *Self) []u8 {
            if (read_only) {
                @compileError("Cannot get mutable metadata from a read-only page");
            }
            const hdr = self.headerMut();
            const hdr_size = hdr.header_size.get();
            const subhdr_end = hdr_size + @as(usize, hdr.subheader_size.get());
            const metadata_end = subhdr_end + @as(usize, hdr.metadata_size.get());
            return self.page[subhdr_end..metadata_end];
        }

        // returns the data availeble for use after the (header + subheader + metadata)
        pub fn data(self: *const Self) []const u8 {
            const all_heades_len = self.allHeadersSize();
            return self.page[all_heades_len..];
        }

        // returns the mutable data availeble for use after the (header + subheader + metadata)
        pub fn dataMut(self: *Self) []u8 {
            if (read_only) {
                @compileError("Cannot get mutable data from a read-only page");
            }
            const all_headers_len = self.allHeadersSize();
            return self.page[all_headers_len..];
        }

        pub fn allHeadersSize(self: *const Self) usize {
            const hdr = self.header();
            const hdr_size = hdr.header_size.get();
            return @as(usize, hdr_size) + @as(usize, hdr.subheader_size.get()) + @as(usize, hdr.metadata_size.get());
        }
    };
}
