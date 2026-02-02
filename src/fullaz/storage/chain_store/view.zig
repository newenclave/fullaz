const std = @import("std");
const PackedInt = @import("../../core/core.zig").packed_int.PackedInt;
const headers = @import("../../page/chain_store.zig");
const subheaders = @import("../../page/subheader.zig");

const PageView = @import("../../page/header.zig").View;
const errors = @import("../../core/errors.zig");

const conracts = @import("../../contracts/contracts.zig");

pub fn View(comptime PageIdT: type, comptime IndexT: type, comptime Endian: std.builtin.Endian, comptime read_only: bool) type {
    const SubheadersType = headers.ChainStore(PageIdT, IndexT, Endian);
    const PageId = PackedInt(PageIdT, Endian);
    const Index = PackedInt(IndexT, Endian);
    const DataType = if (read_only) []const u8 else []u8;

    const CommonErrorSet = errors.PageError;

    const HeaderImpl = struct {
        const Self = @This();
        pub const SubheaderType = SubheadersType.HeaderSubheader;

        pub const Error = error{} || CommonErrorSet;
        body: DataType = undefined,

        pub fn init(data: DataType) Self {
            return .{
                .body = data,
            };
        }

        pub fn formatPage(self: *Self, kind: u16, page_id: PageIdT, metadata_len: IndexT) void {
            if (read_only) {
                @compileError("Cannot format a read-only page");
            }
            var sh = self.subheaderMut();
            sh.flags.set(0);
            sh.total_size.set(0);
            sh.first.setMax();
            sh.last.setMax();
        }

        pub fn subheader(self: *const Self) *const SubheaderType {
            return @ptrCast(@alignCast(&self.body[0]));
        }

        pub fn subheaderMut(self: *Self) *SubheaderType {
            if (read_only) {
                @compileError("Cannot get mutable subheader from a read-only page");
            }
            return @ptrCast(@alignCast(&self.body[0]));
        }
    };

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
            sh.back.setMax();
            sh.fwd.setMax();
            sh.size.set(0);
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

        pub fn getData(self: *const Self) []const u8 {
            return self.page_view.data();
        }

        pub fn getDataMut(self: *Self) []u8 {
            return self.page_view.dataMut();
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
            return sh.size.get();
        }

        pub fn setSize(self: *Self, size: Index) void {
            if (read_only) {
                @compileError("Cannot set size on a read-only chunk");
            }
            const sh = self.subheaderMut();
            sh.size.set(size);
        }
    };

    return struct {
        pub const Header = HeaderImpl;
        pub const Chunk = ChunkImpl;
    };
}
