const std = @import("std");
const PackedInt = @import("../../core/core.zig").packed_int.PackedInt;
const headers = @import("../../page/chain_store.zig");
const subheaders = @import("../../page/subheader.zig");

const PageView = @import("../../page/header.zig").View;
const errors = @import("../../core/errors.zig");

const conracts = @import("../../contracts/contracts.zig");

const LinkImpl = @import("../links/link_view.zig").LinkView;

pub fn View(comptime PageIdT: type, comptime IndexT: type, comptime SizeT: type, comptime Endian: std.builtin.Endian, comptime read_only: bool) type {
    const SubheadersType = headers.ChainStore(PageIdT, IndexT, SizeT, Endian);
    const PageId = PageIdT;
    const Index = IndexT;
    const DataType = if (read_only) []const u8 else []u8;

    const LinkType = LinkImpl(PageIdT, IndexT, SubheadersType.LinkHeader, false);
    const LinkTypeConst = LinkImpl(PageIdT, IndexT, SubheadersType.LinkHeader, true);

    const CommonErrorSet = errors.PageError;

    const ChunkImpl = struct {
        const Self = @This();
        pub const SubheaderType = SubheadersType.ChunkSubheader;
        pub const SubheaderView = subheaders.View(PageIdT, IndexT, SubheaderType, Endian, read_only);

        pub const Error = error{} || CommonErrorSet;
        page_view: SubheaderView = undefined,

        pub fn init(data: DataType) Self {
            return .{
                .page_view = SubheaderView.init(data),
            };
        }

        pub fn formatPage(self: *Self, kind: u16, page_id: PageIdT, metadata_len: IndexT) void {
            if (read_only) {
                @compileError("Cannot format a read-only page");
            }
            self.page_view.formatPage(kind, page_id, metadata_len);
            var sh = self.subheaderMut();
            sh.flags.set(0);
            sh.link.back.setMax();
            sh.link.fwd.setMax();
            sh.link.payload.size.set(0);
        }

        pub fn subheader(self: *const Self) *const SubheaderType {
            return self.page_view.subheader();
        }

        pub fn subheaderMut(self: *Self) *SubheaderType {
            if (read_only) {
                @compileError("Cannot get mutable subheader from a read-only page");
            }
            return self.page_view.subheaderMut();
        }

        // returns the PAGE data; Doesn't include header, subheader, or metadata
        pub fn getData(self: *const Self) []const u8 {
            return self.page_view.page().data();
        }

        // returns the PAGE mutable data; Doesn't include header, subheader, or metadata
        pub fn getDataMut(self: *Self) []u8 {
            var page = self.page_view.pageMut();
            return page.dataMut();
        }

        pub fn getLink(self: *const Self) LinkTypeConst {
            return LinkTypeConst.init(&self.subheader().link);
        }

        pub fn getLinkMut(self: *Self) LinkType {
            if (read_only) {
                @compileError("Cannot get mutable link from a read-only view");
            }
            return LinkType.init(&self.subheaderMut().link);
        }

        pub fn getNext(self: *const Self) ?PageId {
            const sh = self.subheader();
            return if (sh.fwd.isMax()) null else sh.fwd.get();
        }

        pub fn setNext(self: *Self, next: ?PageId) void {
            if (read_only) {
                @compileError("Cannot set next on a read-only chunk");
            }
            const sh = self.subheaderMut();
            if (next) |nid| {
                sh.fwd.set(nid);
            } else {
                sh.fwd.setMax();
            }
        }

        pub fn getPrev(self: *const Self) ?PageId {
            const sh = self.subheader();
            return if (sh.back.isMax()) null else sh.back.get();
        }

        pub fn setPrev(self: *Self, prev: ?PageId) void {
            if (read_only) {
                @compileError("Cannot set prev on a read-only chunk");
            }
            const sh = self.subheaderMut();
            if (prev) |pid| {
                sh.back.set(pid);
            } else {
                sh.back.setMax();
            }
        }

        pub fn getSize(self: *const Self) Index {
            const sh = self.subheader();
            return sh.link.payload.size.get();
        }

        pub fn setSize(self: *Self, size: Index) void {
            if (read_only) {
                @compileError("Cannot set size on a read-only chunk");
            }
            const sh = self.subheaderMut();
            sh.link.payload.size.set(size);
        }

        pub fn getChunkData(self: *const Self) []const u8 {
            const full_data = self.getData();
            const data_size = self.getSize();
            return full_data[0..data_size];
        }

        pub fn getChunkDataMut(self: *Self) []u8 {
            const full_data = self.getDataMut();
            const data_size = self.getSize();
            return full_data[0..data_size];
        }
    };

    return struct {
        pub const Chunk = ChunkImpl;
        pub const Link = LinkImpl(PageIdT, IndexT, SubheadersType.LinkHeader, read_only);
    };
}
