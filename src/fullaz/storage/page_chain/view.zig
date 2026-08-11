const std = @import("std");
const extensions = @import("../../page/extensions.zig");
const Links = @import("../../page/links.zig");

const header = @import("../../page/header.zig");
const errors = @import("../../core/errors.zig");

const conracts = @import("../../contracts/contracts.zig");
const PackedInt = @import("../../core/packed_int.zig").PackedInt;

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
        false,
        Endian,
        read_only,
    );
}

pub fn ViewImpl(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime AdditionalT: type,
    comptime forward_only: bool,
    comptime Endian: std.builtin.Endian,
    comptime read_only: bool,
) type {
    if (forward_only) {
        return ViewForwardImpl(
            PageIdT,
            IndexT,
            AdditionalT,
            Endian,
            read_only,
        );
    } else {
        return ViewBidirectionalImpl(
            PageIdT,
            IndexT,
            AdditionalT,
            Endian,
            read_only,
        );
    }
}

pub fn ViewForwardImpl(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime AdditionalT: type,
    comptime Endian: std.builtin.Endian,
    comptime read_only: bool,
) type {
    const LinkTrait = Links.TraitImpl(PageIdT, true, Endian);

    const AdditionalFields = if (AdditionalT == void)
        extensions.Extend(extensions.Empty, .{
            .version = 1,
            .namespace = "page_chain",
            .fields = .{
                extensions.field("links", LinkTrait),
            },
        })
    else
        extensions.Extend(AdditionalT, .{
            .version = AdditionalT.page_version,
            .namespace = "page_chain",
            .fields = .{
                extensions.field("links", LinkTrait),
            },
        });

    const DataType = if (read_only) []const u8 else []u8;

    const PageViewImpl = header.ViewImpl(
        PageIdT,
        IndexT,
        AdditionalFields,
        Endian,
        read_only,
    );

    const PageHeaderImpl = PageViewImpl.PageHeader;

    const ChunkImpl = struct {
        const Self = @This();

        page_view: PageViewImpl = undefined,

        pub fn init(page_data: DataType) Self {
            return .{
                .page_view = PageViewImpl.init(page_data),
            };
        }

        pub fn formatPage(
            self: *Self,
            kind: u16,
            page_id: PageIdT,
            subheader_len: IndexT,
            metadata_len: IndexT,
        ) void {
            if (read_only) {
                @compileError("Cannot format a read-only page");
            }
            self.page_view.formatPage(
                kind,
                page_id,
                subheader_len,
                metadata_len,
            );
        }

        pub fn header(self: *const Self) *const PageHeaderImpl {
            return self.page_view.header();
        }

        pub fn headerMut(self: *Self) *PageHeaderImpl {
            if (read_only) {
                @compileError("Cannot get mutable header from a read-only page");
            }
            return self.page_view.headerMut();
        }

        pub fn subheader(self: *const Self) []const u8 {
            return self.page_view.subheader();
        }

        pub fn subheaderMut(self: *Self) []u8 {
            if (read_only) {
                @compileError("Cannot get mutable subheader from a read-only page");
            }
            return self.page_view.subheaderMut();
        }

        pub fn metadata(self: *const Self) []const u8 {
            return self.page_view.metadata();
        }

        pub fn metadataMut(self: *Self) []u8 {
            if (read_only) {
                @compileError("Cannot get mutable metadata from a read-only page");
            }
            return self.page_view.metadataMut();
        }

        pub fn pageView(self: *const Self) *const PageViewImpl {
            return &self.page_view;
        }

        pub fn pageViewMut(self: *Self) *PageViewImpl {
            if (read_only) {
                @compileError("Cannot get mutable page from a read-only page");
            }
            return &self.page_view;
        }

        pub fn page(self: *const Self) []const u8 {
            return self.page_view.page;
        }

        pub fn pageMut(self: *Self) []u8 {
            if (read_only) {
                @compileError("Cannot get mutable page from a read-only page");
            }
            return self.page_view.page;
        }

        pub fn data(self: *const Self) []const u8 {
            return self.page_view.data();
        }

        pub fn dataMut(self: *Self) []u8 {
            if (read_only) {
                @compileError("Cannot get mutable data from a read-only page");
            }
            return self.page_view.dataMut();
        }

        pub fn getNext(self: *const Self) ?PageIdT {
            const links_view = self.links();
            return LinkTrait.getNext(links_view);
        }

        pub fn setNext(self: *Self, pid: ?PageIdT) void {
            const links_view = self.linksMut();
            LinkTrait.setNext(links_view, pid);
        }

        fn links(self: *const Self) *const LinkTrait.Storage {
            return &self.page_view.header().additional.page_chain.links;
        }

        fn linksMut(self: *Self) *LinkTrait.Storage {
            return &self.page_view.headerMut().additional.page_chain.links;
        }
    };

    return struct {
        pub const Chunk = ChunkImpl;
        pub const PageView = PageViewImpl;
        pub const PageHeader = PageHeaderImpl;
    };
}

pub fn ViewBidirectionalImpl(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime AdditionalT: type,
    comptime Endian: std.builtin.Endian,
    comptime read_only: bool,
) type {
    const LinkTrait = Links.TraitImpl(PageIdT, false, Endian);

    const AdditionalFields = if (AdditionalT == void)
        extensions.Extend(extensions.Empty, .{
            .version = 1,
            .namespace = "page_chain",
            .fields = .{
                extensions.field("links", LinkTrait),
            },
        })
    else
        extensions.Extend(AdditionalT, .{
            .version = AdditionalT.page_version,
            .namespace = "page_chain",
            .fields = .{
                extensions.field("links", LinkTrait),
            },
        });

    const DataType = if (read_only) []const u8 else []u8;

    const PageViewImpl = header.ViewImpl(
        PageIdT,
        IndexT,
        AdditionalFields,
        Endian,
        read_only,
    );

    const PageHeaderImpl = PageViewImpl.PageHeader;

    const ChunkImpl = struct {
        const Self = @This();

        page_view: PageViewImpl = undefined,

        pub fn init(page_data: DataType) Self {
            return .{
                .page_view = PageViewImpl.init(page_data),
            };
        }

        pub fn formatPage(
            self: *Self,
            kind: u16,
            page_id: PageIdT,
            subheader_len: IndexT,
            metadata_len: IndexT,
        ) void {
            if (read_only) {
                @compileError("Cannot format a read-only page");
            }
            self.page_view.formatPage(
                kind,
                page_id,
                subheader_len,
                metadata_len,
            );
        }

        pub fn header(self: *const Self) *const PageHeaderImpl {
            return self.page_view.header();
        }

        pub fn headerMut(self: *Self) *PageHeaderImpl {
            if (read_only) {
                @compileError("Cannot get mutable header from a read-only page");
            }
            return self.page_view.headerMut();
        }

        pub fn subheader(self: *const Self) []const u8 {
            return self.page_view.subheader();
        }

        pub fn subheaderMut(self: *Self) []u8 {
            if (read_only) {
                @compileError("Cannot get mutable subheader from a read-only page");
            }
            return self.page_view.subheaderMut();
        }

        pub fn metadata(self: *const Self) []const u8 {
            return self.page_view.metadata();
        }

        pub fn metadataMut(self: *Self) []u8 {
            if (read_only) {
                @compileError("Cannot get mutable metadata from a read-only page");
            }
            return self.page_view.metadataMut();
        }

        pub fn pageView(self: *const Self) *const PageViewImpl {
            return &self.page_view;
        }

        pub fn pageViewMut(self: *Self) *PageViewImpl {
            if (read_only) {
                @compileError("Cannot get mutable page from a read-only page");
            }
            return &self.page_view;
        }

        pub fn page(self: *const Self) []const u8 {
            return self.page_view.page;
        }

        pub fn pageMut(self: *Self) []u8 {
            if (read_only) {
                @compileError("Cannot get mutable page from a read-only page");
            }
            return self.page_view.page;
        }

        pub fn data(self: *const Self) []const u8 {
            return self.page_view.data();
        }

        pub fn dataMut(self: *Self) []u8 {
            if (read_only) {
                @compileError("Cannot get mutable data from a read-only page");
            }
            return self.page_view.dataMut();
        }

        pub fn getPrev(self: *const Self) ?PageIdT {
            const links_view = self.links();
            return LinkTrait.getPrev(links_view);
        }

        pub fn setPrev(self: *Self, pid: ?PageIdT) void {
            const links_view = self.linksMut();
            LinkTrait.setPrev(links_view, pid);
        }

        pub fn getNext(self: *const Self) ?PageIdT {
            const links_view = self.links();
            return LinkTrait.getNext(links_view);
        }

        pub fn setNext(self: *Self, pid: ?PageIdT) void {
            const links_view = self.linksMut();
            LinkTrait.setNext(links_view, pid);
        }

        fn links(self: *const Self) *const LinkTrait.Storage {
            return &self.page_view.header().additional.page_chain.links;
        }

        fn linksMut(self: *Self) *LinkTrait.Storage {
            return &self.page_view.headerMut().additional.page_chain.links;
        }
    };

    return struct {
        pub const Chunk = ChunkImpl;
        pub const PageView = PageViewImpl;
        pub const PageHeader = PageHeaderImpl;
    };
}
