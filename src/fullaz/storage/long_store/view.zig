const std = @import("std");
const headers = @import("../../page/long_store.zig");
const subheaders = @import("../../page/subheader.zig");
const PageView = @import("../../page/header.zig").View;
const errors = @import("../../core/errors.zig");

const conracts = @import("../../contracts/contracts.zig");

// Shared logic is currently duplicated per view for clarity and stability.

fn LinkImpl(comptime PageId: type, comptime Index: type, comptime LinkHeader: type, comptime read_only: bool) type {
    const FldType = if (read_only) *const LinkHeader else *LinkHeader;
    return struct {
        const Self = @This();
        pub const Error = error{} || errors.SpaceError;

        link: FldType = undefined,

        pub fn init(link: FldType) Self {
            return Self{
                .link = link,
            };
        }

        pub fn getFwd(self: *const Self) ?PageId {
            const val = self.link.fwd.get();
            return if (val == @TypeOf(self.link.fwd).max()) null else val;
        }

        pub fn setFwd(self: *Self, next: ?PageId) void {
            if (read_only) {
                @compileError("Cannot set next on a read-only view");
            }
            if (next) |n| {
                self.link.fwd.set(n);
            } else {
                self.link.fwd.set(@TypeOf(self.link.fwd).max());
            }
        }

        pub fn getBack(self: *const Self) ?PageId {
            const val = self.link.back.get();
            return if (val == @TypeOf(self.link.back).max()) null else val;
        }

        pub fn setBack(self: *Self, last: ?PageId) void {
            if (read_only) {
                @compileError("Cannot set last on a read-only view");
            }
            if (last) |l| {
                self.link.back.set(l);
            } else {
                self.link.back.set(@TypeOf(self.link.back).max());
            }
        }

        pub fn getDataSize(self: *const Self) Index {
            return self.link.payload.size.get();
        }

        pub fn setDataSize(self: *Self, size: Index) void {
            if (read_only) {
                @compileError("Cannot set data size on a read-only view");
            }
            self.link.payload.size.set(size);
        }

        pub fn incrementDataSize(self: *Self, increment: Index) void {
            if (read_only) {
                @compileError("Cannot increment data size on a read-only view");
            }
            const current = self.link.payload.size.get();
            self.link.payload.size.set(current + increment);
        }

        pub fn decrementDataSize(self: *Self, decrement: Index) void {
            if (read_only) {
                @compileError("Cannot decrement data size on a read-only view");
            }
            const current = self.link.payload.size.get();
            self.link.payload.size.set(current - decrement);
        }
    };
}

pub fn View(comptime PageIdT: type, comptime IndexT: type, comptime SizeT: type, comptime Endian: std.builtin.Endian, comptime read_only: bool) type {
    const SubheadersType = headers.LongStore(PageIdT, IndexT, SizeT, Endian);
    const DataType = if (read_only) []const u8 else []u8;

    const HeaderPageView = PageView(PageIdT, IndexT, Endian, read_only);

    const CommonErrorSet = errors.SpaceError;
    const LinkType = LinkImpl(PageIdT, IndexT, SubheadersType.LinkHeader, false);
    const LinkTypeConst = LinkImpl(PageIdT, IndexT, SubheadersType.LinkHeader, true);

    const HeaderViewImpl = struct {
        const Self = @This();
        pub const SubheaderType = SubheadersType.HeaderSubheader;
        pub const HeaderType = HeaderPageView.PageHeader;

        pub const SubheaderView = subheaders.View(PageIdT, IndexT, SubheaderType, Endian, read_only);

        pub const Error = error{} || CommonErrorSet;

        page_view: SubheaderView = undefined,

        pub fn init(body: DataType) Self {
            return Self{
                .page_view = SubheaderView.init(body),
            };
        }

        pub fn formatPage(self: *Self, kind: u16, page_id: PageIdT, metadata_len: IndexT) void {
            if (read_only) {
                @compileError("Cannot format a read-only page");
            }
            self.page_view.formatPage(kind, page_id, metadata_len);
            var sh = self.subheaderMut();
            sh.total_size.set(0);
            sh.link.back.set(@TypeOf(sh.link.back).max());
            sh.link.fwd.set(@TypeOf(sh.link.fwd).max());
            sh.link.payload.size.set(0);
            sh.link.payload.reserved.set(0);
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
        pub fn pageView(self: *const Self) *const HeaderPageView {
            return &self.page_view.page_view;
        }

        pub fn pageViewMut(self: *Self) *HeaderPageView {
            return &self.page_view.page_view;
        }

        pub fn data(self: *const Self) []const u8 {
            return self.pageView().data();
        }

        pub fn dataMut(self: *Self) []u8 {
            if (read_only) {
                @compileError("Cannot get mutable data from a read-only page");
            }
            return self.pageViewMut().dataMut();
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

        pub fn getTotalSize(self: *const Self) SizeT {
            const sh = self.subheader();
            return sh.total_size.get();
        }

        pub fn setTotalSize(self: *Self, total_size: SizeT) void {
            if (read_only) {
                @compileError("Cannot set total_size on a read-only view");
            }
            var sh = self.subheaderMut();
            sh.total_size.set(total_size);
        }

        pub fn incrementTotalSize(self: *Self, increment: SizeT) void {
            if (read_only) {
                @compileError("Cannot increment total_size on a read-only view");
            }
            var sh = self.subheaderMut();
            const current = sh.total_size.get();
            sh.total_size.set(current + increment);
        }

        pub fn decrementTotalSize(self: *Self, decrement: SizeT) void {
            if (read_only) {
                @compileError("Cannot decrement total_size on a read-only view");
            }
            var sh = self.subheaderMut();
            const current = sh.total_size.get();
            sh.total_size.set(current - decrement);
        }
    };

    const ChunkViewImpl = struct {
        const Self = @This();
        pub const SubheaderType = SubheadersType.ChunkSubheader;
        pub const HeaderType = HeaderPageView.PageHeader;

        pub const SubheaderView = subheaders.View(PageIdT, IndexT, SubheaderType, Endian, read_only);
        pub const PageView = SubheaderView.PageView;
        pub const Flags = SubheadersType.ChunkFlags;

        pub const Error = error{} || CommonErrorSet;

        page_view: SubheaderView = undefined,

        pub fn init(body: DataType) Self {
            return Self{
                .page_view = SubheaderView.init(body),
            };
        }

        pub fn formatPage(self: *Self, kind: u16, page_id: PageIdT, metadata_len: IndexT) void {
            if (read_only) {
                @compileError("Cannot format a read-only page");
            }
            self.page_view.formatPage(kind, page_id, metadata_len);
            var sh = self.subheaderMut();
            sh.link.back.setMax();
            sh.link.fwd.setMax();
            sh.link.payload.size.set(0);
            sh.flags.set(0);
            sh.link.payload.reserved.set(0);
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

        pub fn pageView(self: *const Self) *const HeaderPageView {
            return &self.page_view.page_view;
        }

        pub fn pageViewMut(self: *Self) *HeaderPageView {
            return &self.page_view.page_view;
        }

        pub fn data(self: *const Self) []const u8 {
            return self.pageView().data();
        }

        pub fn dataMut(self: *Self) []u8 {
            if (read_only) {
                @compileError("Cannot get mutable data from a read-only page");
            }
            return self.pageViewMut().dataMut();
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

        pub fn hasFlag(self: *const Self, flag: Flags) bool {
            const sh = self.subheader();
            return (sh.flags.get() & @intFromEnum(flag)) != 0;
        }

        pub fn setFlag(self: *Self, flag: Flags) void {
            if (read_only) {
                @compileError("Cannot set flag on a read-only view");
            }
            var sh = self.subheaderMut();
            sh.flags.set(sh.flags.get() | @intFromEnum(flag));
        }

        pub fn clearFlag(self: *Self, flag: Flags) void {
            if (read_only) {
                @compileError("Cannot clear flag on a read-only view");
            }
            var sh = self.subheaderMut();
            sh.flags.set(sh.flags.get() & ~@intFromEnum(flag));
        }
    };

    return struct {
        pub const HeaderView = HeaderViewImpl;
        pub const ChunkView = ChunkViewImpl;
        pub const Link = LinkImpl(PageIdT, IndexT, SubheadersType.LinkHeader, read_only);
    };
}
