const std = @import("std");
const errors = @import("../../../../core/errors.zig");
const header = @import("../../../../page/header.zig");
const orthtree_page = @import("../../../../page/orthtree.zig");
const geometry = @import("../../../geometry.zig");

pub fn View(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime CoordT: type,
    comptime dims: usize,
    comptime TraitStorage: type,
    comptime Endian: std.builtin.Endian,
    comptime read_only: bool,
) type {
    const OrthtreePage = orthtree_page.Orthtree(PageIdT, IndexT, CoordT, dims, Endian);
    const HeaderPageView = header.View(PageIdT, IndexT, Endian, read_only);
    const NodeSubheader = OrthtreePage.NodeSubheader;
    const Mbr = OrthtreePage.Mbr;
    const Key = geometry.BoundingBox(CoordT, dims);
    const trait_size = @sizeOf(TraitStorage);
    const subheader_size = @sizeOf(NodeSubheader);

    comptime {
        if (@alignOf(TraitStorage) != 1) {
            @compileError("Orthtree trait storage must have alignment 1");
        }
        if (trait_size == 0) {
            @compileError("Orthtree trait storage must not be empty");
        }
        if (trait_size > std.math.maxInt(IndexT) or subheader_size > std.math.maxInt(IndexT)) {
            @compileError("Orthtree trait storage or subheader exceeds IndexT capacity");
        }
    }

    const encodeMbr = struct {
        fn call(dst: *Mbr, bounds: Key) void {
            inline for (0..dims) |axis| {
                dst.low[axis].set(bounds.low[axis]);
                dst.high[axis].set(bounds.high[axis]);
            }
        }
    }.call;

    const decodeMbr = struct {
        fn call(src: *const Mbr) Key {
            var bounds = Key.init();
            inline for (0..dims) |axis| {
                bounds.low[axis] = src.low[axis].get();
                bounds.high[axis] = src.high[axis].get();
            }
            return bounds;
        }
    }.call;

    const idOrNull = struct {
        fn call(id: *const OrthtreePage.PageId) ?PageIdT {
            if (id.isMax()) {
                return null;
            }
            return id.get();
        }
    }.call;

    const NodeImpl = struct {
        const Self = @This();
        const DataType = if (read_only) []const u8 else []u8;

        pub const Error = errors.PageError || errors.IndexError || HeaderPageView.Error;
        pub const PageView = HeaderPageView;
        pub const Trait = TraitStorage;
        pub const Box = Key;
        pub const EntryChain = struct {
            first: ?PageIdT,
            last: ?PageIdT,
            count: usize,
        };

        page_view: HeaderPageView,

        pub fn init(data: DataType) Self {
            return .{ .page_view = HeaderPageView.init(data) };
        }

        pub fn formatPage(self: *Self, kind: u16, page_id: PageIdT, node_bounds: Box, trait_template: *const Trait) void {
            if (read_only) {
                @compileError("Cannot format a read-only page");
            }
            self.page_view.formatPage(
                kind,
                page_id,
                @as(IndexT, @intCast(subheader_size)),
                @as(IndexT, @intCast(trait_size)),
            );
            var node_subheader = self.subheaderMut();
            node_subheader.formatHeader();
            encodeMbr(&node_subheader.bounds, node_bounds);
            @memcpy(self.page_view.metadataMut(), std.mem.asBytes(trait_template));
        }

        pub fn validatePage(self: *const Self, page_id: PageIdT) Error!void {
            try self.page_view.validateTyped();
            const page_header = self.page_view.header();
            if (page_header.self_pid.get() != page_id) {
                return Error.BadData;
            }
            if (@as(usize, @intCast(page_header.subheader_size.get())) != subheader_size) {
                return Error.BadData;
            }
            if (@as(usize, @intCast(page_header.metadata_size.get())) != trait_size) {
                return Error.BadData;
            }

            const node_subheader = self.subheader();
            if ((node_subheader.flags & ~OrthtreePage.NodeFlags.internal) != 0) {
                return Error.BadData;
            }
            if (!std.mem.eql(u8, &node_subheader.reserved, &[_]u8{ 0, 0 })) {
                return Error.BadData;
            }

            const entries_empty = node_subheader.entries_count.get() == 0;
            const entries_unlinked = node_subheader.entries_first.isMax() and node_subheader.entries_last.isMax();
            if (entries_empty != entries_unlinked) {
                return Error.BadData;
            }
            if (self.isLeaf()) {
                inline for (0..OrthtreePage.children_per_node) |index| {
                    if (!node_subheader.children[index].isMax()) {
                        return Error.BadData;
                    }
                }
            }
        }

        pub fn header(self: *const Self) *const HeaderPageView.PageHeader {
            return self.page_view.header();
        }

        pub fn headerMut(self: *Self) *HeaderPageView.PageHeader {
            if (read_only) {
                @compileError("Cannot get a mutable header from a read-only page");
            }
            return self.page_view.headerMut();
        }

        pub fn subheader(self: *const Self) *const NodeSubheader {
            const bytes = self.page_view.subheader();
            return @ptrCast(@alignCast(&bytes[0]));
        }

        pub fn subheaderMut(self: *Self) *NodeSubheader {
            if (read_only) {
                @compileError("Cannot get a mutable subheader from a read-only page");
            }
            const bytes = self.page_view.subheaderMut();
            return @ptrCast(@alignCast(&bytes[0]));
        }

        pub fn trait(self: *const Self) *const Trait {
            const bytes = self.page_view.metadata();
            return @ptrCast(@alignCast(&bytes[0]));
        }

        pub fn traitMut(self: *Self) *Trait {
            if (read_only) {
                @compileError("Cannot get a mutable trait from a read-only page");
            }
            const bytes = self.page_view.metadataMut();
            return @ptrCast(@alignCast(&bytes[0]));
        }

        pub fn bounds(self: *const Self) Box {
            return decodeMbr(&self.subheader().bounds);
        }

        pub fn setBounds(self: *Self, node_bounds: Box) void {
            encodeMbr(&self.subheaderMut().bounds, node_bounds);
        }

        pub fn getParent(self: *const Self) ?PageIdT {
            return idOrNull(&self.subheader().parent);
        }

        pub fn setParent(self: *Self, parent: ?PageIdT) void {
            if (parent) |page_id| {
                self.subheaderMut().parent.set(page_id);
            } else {
                self.subheaderMut().parent.setMax();
            }
        }

        pub fn entryChain(self: *const Self) EntryChain {
            const node_subheader = self.subheader();
            return .{
                .first = idOrNull(&node_subheader.entries_first),
                .last = idOrNull(&node_subheader.entries_last),
                .count = @intCast(node_subheader.entries_count.get()),
            };
        }

        pub fn setEntryChain(self: *Self, first: ?PageIdT, last: ?PageIdT, count: usize) Error!void {
            if ((count == 0 and (first != null or last != null)) or (count != 0 and (first == null or last == null))) {
                return Error.BadData;
            }
            const stored_count = std.math.cast(u32, count) orelse return Error.BadData;
            const node_subheader = self.subheaderMut();
            if (first) |page_id| {
                node_subheader.entries_first.set(page_id);
            } else {
                node_subheader.entries_first.setMax();
            }
            if (last) |page_id| {
                node_subheader.entries_last.set(page_id);
            } else {
                node_subheader.entries_last.setMax();
            }
            node_subheader.entries_count.set(stored_count);
        }

        pub fn isLeaf(self: *const Self) bool {
            return (self.subheader().flags & OrthtreePage.NodeFlags.internal) == 0;
        }

        pub fn setInternal(self: *Self) void {
            self.subheaderMut().flags |= OrthtreePage.NodeFlags.internal;
        }

        pub fn getLevel(self: *const Self) usize {
            return self.subheader().level;
        }

        pub fn setLevel(self: *Self, level: usize) Error!void {
            const stored_level = std.math.cast(u8, level) orelse return Error.BadData;
            self.subheaderMut().level = stored_level;
        }

        pub fn getChild(self: *const Self, index: usize) Error!?PageIdT {
            if (index >= OrthtreePage.children_per_node) {
                return Error.OutOfBounds;
            }
            return idOrNull(&self.subheader().children[index]);
        }

        pub fn setChild(self: *Self, index: usize, child: ?PageIdT) Error!void {
            if (index >= OrthtreePage.children_per_node) {
                return Error.OutOfBounds;
            }
            if (child) |page_id| {
                self.subheaderMut().children[index].set(page_id);
            } else {
                self.subheaderMut().children[index].setMax();
            }
        }
    };

    return struct {
        pub const Node = NodeImpl;
        pub const Box = Node.Box;
        pub const Trait = TraitStorage;
    };
}
