const std = @import("std");
const headers = @import("../../page/long_store.zig");
const subheaders = @import("../../page/subheader.zig");
const PageView = @import("../../page/header.zig").View;
const errors = @import("../../core/errors.zig");

const conracts = @import("../../contracts/contracts.zig");

// Shared logic is currently duplicated per view for clarity and stability.

pub fn View(comptime PageIdT: type, comptime IndexT: type, comptime SizeT: type, comptime Endian: std.builtin.Endian, comptime read_only: bool) type {
    const SubheadersType = headers.LongStore(PageIdT, IndexT, SizeT, Endian);
    const DataType = if (read_only) []const u8 else []u8;

    const HeaderPageView = PageView(PageIdT, IndexT, Endian, read_only);

    const CommonErrorSet = errors.SpaceError;

    // const Common = struct {
    //     const Self = @This();
    //     pub const Error = error{} || CommonErrorSet;
    // };

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
            sh.last.set(@TypeOf(sh.last).max());
            sh.common.next.set(@TypeOf(sh.common.next).max());
            sh.common.data.size.set(0);
            sh.common.data.reserved.set(0);
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

        pub fn getNext(self: *const Self) ?PageIdT {
            const sh = self.subheader();
            const val = sh.common.next.get();
            return if (val == @TypeOf(sh.common.next).max()) null else val;
        }

        pub fn setNext(self: *Self, next: ?PageIdT) void {
            if (read_only) {
                @compileError("Cannot set next on a read-only view");
            }
            var sh = self.subheaderMut();
            if (next) |n| {
                sh.common.next.set(n);
            } else {
                sh.common.next.set(@TypeOf(sh.common.next).max());
            }
        }

        pub fn getLast(self: *const Self) ?PageIdT {
            const sh = self.subheader();
            const val = sh.last.get();
            return if (val == std.math.maxInt(PageIdT)) null else val;
        }

        pub fn setLast(self: *Self, last: ?PageIdT) void {
            if (read_only) {
                @compileError("Cannot set last on a read-only view");
            }
            var sh = self.subheaderMut();
            if (last) |l| {
                sh.last.set(l);
            } else {
                sh.last.set(std.math.maxInt(PageIdT));
            }
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

        pub fn getDataSize(self: *const Self) IndexT {
            const sh = self.subheader();
            return sh.common.data.size.get();
        }

        pub fn setDataSize(self: *Self, size: IndexT) void {
            if (read_only) {
                @compileError("Cannot set data size on a read-only view");
            }
            var sh = self.subheaderMut();
            sh.common.data.size.set(size);
        }

        pub fn incrementDataSize(self: *Self, increment: IndexT) void {
            if (read_only) {
                @compileError("Cannot increment data size on a read-only view");
            }
            var sh = self.subheaderMut();
            const current = sh.common.data.size.get();
            sh.common.data.size.set(current + increment);
        }

        pub fn decrementDataSize(self: *Self, decrement: IndexT) void {
            if (read_only) {
                @compileError("Cannot decrement data size on a read-only view");
            }
            var sh = self.subheaderMut();
            const current = sh.common.data.size.get();
            sh.common.data.size.set(current - decrement);
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
            sh.prev.set(@TypeOf(sh.prev).max());
            sh.common.next.set(@TypeOf(sh.common.next).max());
            sh.common.data.size.set(0);
            sh.flags.set(0);
            sh.common.data.reserved.set(0);
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

        pub fn getNext(self: *const Self) ?PageIdT {
            const sh = self.subheader();
            const val = sh.common.next.get();
            return if (val == std.math.maxInt(PageIdT)) null else val;
        }

        pub fn setNext(self: *Self, next: ?PageIdT) void {
            if (read_only) {
                @compileError("Cannot set next on a read-only view");
            }
            var sh = self.subheaderMut();
            if (next) |n| {
                sh.common.next.set(n);
            } else {
                sh.common.next.set(std.math.maxInt(PageIdT));
            }
        }

        pub fn getPrev(self: *const Self) ?PageIdT {
            const sh = self.subheader();
            const val = sh.prev.get();
            return if (val == std.math.maxInt(PageIdT)) null else val;
        }

        pub fn setPrev(self: *Self, prev: ?PageIdT) void {
            if (read_only) {
                @compileError("Cannot set prev on a read-only view");
            }
            var sh = self.subheaderMut();
            if (prev) |p| {
                sh.prev.set(p);
            } else {
                sh.prev.set(std.math.maxInt(PageIdT));
            }
        }

        pub fn getDataSize(self: *const Self) IndexT {
            const sh = self.subheader();
            return sh.common.data.size.get();
        }

        pub fn setDataSize(self: *Self, size: IndexT) void {
            if (read_only) {
                @compileError("Cannot set data size on a read-only view");
            }
            var sh = self.subheaderMut();
            sh.common.data.size.set(size);
        }

        pub fn incrementDataSize(self: *Self, increment: IndexT) void {
            if (read_only) {
                @compileError("Cannot increment data size on a read-only view");
            }
            var sh = self.subheaderMut();
            const current = sh.common.data.size.get();
            sh.common.data.size.set(current + increment);
        }

        pub fn decrementDataSize(self: *Self, decrement: IndexT) void {
            if (read_only) {
                @compileError("Cannot decrement data size on a read-only view");
            }
            var sh = self.subheaderMut();
            const current = sh.common.data.size.get();
            sh.common.data.size.set(current - decrement);
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
    };
}
