const std = @import("std");
const errors = @import("../../../../core/errors.zig");
const header = @import("../../../../page/header.zig");
const orthtree_page = @import("../../../../page/orthtree.zig");
const geometry = @import("../../../geometry.zig");
const fixed_slots = @import("../../../../slots/fixed.zig");

pub fn View(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime CoordT: type,
    comptime dims: usize,
    comptime TraitStorageT: type,
    comptime Endian: std.builtin.Endian,
    comptime read_only: bool,
) type {
    const OrthtreePage = orthtree_page.Orthtree(PageIdT, IndexT, CoordT, dims, Endian);
    const HeaderPageView = header.View(PageIdT, IndexT, Endian, read_only);
    const NodeSubheader = OrthtreePage.NodeSubheader;
    const Mbr = OrthtreePage.Mbr;
    const Key = geometry.BoundingBox(CoordT, dims);
    const trait_size = @sizeOf(TraitStorageT);
    const subheader_size = @sizeOf(NodeSubheader);

    comptime {
        if (@alignOf(TraitStorageT) != 1) {
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
        pub const Trait = TraitStorageT;
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

            const first_unlinked = node_subheader.entries_first.isMax();
            const last_unlinked = node_subheader.entries_last.isMax();
            if (first_unlinked != last_unlinked) {
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
            if ((first == null) != (last == null)) {
                return Error.BadData;
            }
            try self.setEntryChainUnchecked(first, last, count);
        }

        pub fn setEntryChainUnchecked(self: *Self, first: ?PageIdT, last: ?PageIdT, count: usize) Error!void {
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
        pub const Trait = TraitStorageT;
    };
}

pub fn PackedView(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime CoordT: type,
    comptime dims: usize,
    comptime TraitStorageT: type,
    comptime Endian: std.builtin.Endian,
    comptime read_only: bool,
) type {
    const OrthtreePage = orthtree_page.Orthtree(PageIdT, IndexT, CoordT, dims, Endian);
    const HeaderPageView = header.View(PageIdT, IndexT, Endian, read_only);
    const NodePageSubheader = OrthtreePage.NodePageSubheader;
    const NodeSlotSubheader = OrthtreePage.NodeSlotSubheader;
    const NodeRef = OrthtreePage.NodeRef;
    const NodeId = OrthtreePage.NodeId;
    const Mbr = OrthtreePage.Mbr;
    const Key = geometry.BoundingBox(CoordT, dims);
    const FixedSlots = fixed_slots.Fixed(u64, IndexT, Endian, read_only);
    const ConstFixedSlots = fixed_slots.Fixed(u64, IndexT, Endian, true);
    const trait_size = @sizeOf(TraitStorageT);
    const slot_header_size = @sizeOf(NodeSlotSubheader);
    const slot_size = slot_header_size + trait_size;

    comptime {
        if (@alignOf(TraitStorageT) != 1) {
            @compileError("Orthtree trait storage must have alignment 1");
        }
        if (trait_size == 0) {
            @compileError("Orthtree trait storage must not be empty");
        }
        if (slot_size > std.math.maxInt(IndexT)) {
            @compileError("Orthtree node slot exceeds IndexT capacity");
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

    const pageIdOrNull = struct {
        fn call(id: *const OrthtreePage.PageId) ?PageIdT {
            if (id.isMax()) {
                return null;
            }
            return id.get();
        }
    }.call;

    const nodeIdOrNull = struct {
        fn call(id: *const NodeRef) ?NodeId {
            if (id.page_id.isMax() or id.slot_id.isMax()) {
                return null;
            }
            return .{
                .page_id = id.page_id.get(),
                .slot_id = id.slot_id.get(),
            };
        }
    }.call;

    const setNodeId = struct {
        fn call(dst: *NodeRef, id: ?NodeId) void {
            if (id) |value| {
                dst.page_id.set(value.page_id);
                dst.slot_id.set(value.slot_id);
            } else {
                dst.format();
            }
        }
    }.call;

    const NodeSlotImpl = struct {
        const Self = @This();
        const DataType = if (read_only) []const u8 else []u8;

        pub const Error = errors.PageError || errors.IndexError;
        pub const Trait = TraitStorageT;
        pub const Box = Key;
        pub const EntryChain = struct {
            first: ?PageIdT,
            last: ?PageIdT,
            count: usize,
        };

        data: DataType,

        pub fn init(data: DataType) Self {
            return .{ .data = data };
        }

        pub fn formatSlot(self: *Self, node_bounds: Box, trait_template: *const Trait) void {
            if (read_only) {
                @compileError("Cannot format a read-only node slot");
            }
            if (self.data.len != slot_size) {
                @panic("Orthtree node slot has an unexpected size");
            }
            var node_subheader = self.subheaderMut();
            node_subheader.formatHeader();
            encodeMbr(&node_subheader.bounds, node_bounds);
            @memcpy(self.traitBytesMut(), std.mem.asBytes(trait_template));
        }

        pub fn validate(self: *const Self) Error!void {
            if (self.data.len != slot_size) {
                return Error.BadData;
            }
            const node_subheader = self.subheader();
            if ((node_subheader.flags & ~OrthtreePage.NodeFlags.internal) != 0 or
                !std.mem.eql(u8, &node_subheader.reserved, &[_]u8{ 0, 0 }))
            {
                return Error.BadData;
            }
            if (node_subheader.parent.page_id.isMax() != node_subheader.parent.slot_id.isMax()) {
                return Error.BadData;
            }
            if (node_subheader.entries_first.isMax() != node_subheader.entries_last.isMax()) {
                return Error.BadData;
            }
            inline for (0..OrthtreePage.children_per_node) |index| {
                const child = &node_subheader.children[index];
                if (child.page_id.isMax() != child.slot_id.isMax()) {
                    return Error.BadData;
                }
                if (self.isLeaf() and !child.page_id.isMax()) {
                    return Error.BadData;
                }
            }
        }

        pub fn subheader(self: *const Self) *const NodeSlotSubheader {
            return @ptrCast(@alignCast(self.data.ptr));
        }

        pub fn subheaderMut(self: *Self) *NodeSlotSubheader {
            if (read_only) {
                @compileError("Cannot get a mutable node slot subheader from a read-only view");
            }
            return @ptrCast(@alignCast(self.data.ptr));
        }

        fn traitBytes(self: *const Self) []const u8 {
            return self.data[slot_header_size..slot_size];
        }

        fn traitBytesMut(self: *Self) []u8 {
            if (read_only) {
                @compileError("Cannot get mutable trait bytes from a read-only node slot");
            }
            return self.data[slot_header_size..slot_size];
        }

        pub fn trait(self: *const Self) *const Trait {
            return @ptrCast(@alignCast(self.traitBytes().ptr));
        }

        pub fn traitMut(self: *Self) *Trait {
            if (read_only) {
                @compileError("Cannot get a mutable trait from a read-only node slot");
            }
            return @ptrCast(@alignCast(self.traitBytesMut().ptr));
        }

        pub fn bounds(self: *const Self) Box {
            return decodeMbr(&self.subheader().bounds);
        }

        pub fn setBounds(self: *Self, node_bounds: Box) void {
            encodeMbr(&self.subheaderMut().bounds, node_bounds);
        }

        pub fn getParent(self: *const Self) ?NodeId {
            return nodeIdOrNull(&self.subheader().parent);
        }

        pub fn setParent(self: *Self, parent: ?NodeId) void {
            setNodeId(&self.subheaderMut().parent, parent);
        }

        pub fn entryChain(self: *const Self) EntryChain {
            const node_subheader = self.subheader();
            return .{
                .first = pageIdOrNull(&node_subheader.entries_first),
                .last = pageIdOrNull(&node_subheader.entries_last),
                .count = @intCast(node_subheader.entries_count.get()),
            };
        }

        pub fn setEntryChain(self: *Self, first: ?PageIdT, last: ?PageIdT, count: usize) Error!void {
            if ((first == null) != (last == null)) {
                return Error.BadData;
            }
            try self.setEntryChainUnchecked(first, last, count);
        }

        pub fn setEntryChainUnchecked(self: *Self, first: ?PageIdT, last: ?PageIdT, count: usize) Error!void {
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

        pub fn getChild(self: *const Self, index: usize) Error!?NodeId {
            if (index >= OrthtreePage.children_per_node) {
                return Error.OutOfBounds;
            }
            return nodeIdOrNull(&self.subheader().children[index]);
        }

        pub fn setChild(self: *Self, index: usize, child: ?NodeId) Error!void {
            if (index >= OrthtreePage.children_per_node) {
                return Error.OutOfBounds;
            }
            setNodeId(&self.subheaderMut().children[index], child);
        }
    };

    const NodePageImpl = struct {
        const Self = @This();
        const DataType = if (read_only) []const u8 else []u8;

        pub const Error = NodeSlotImpl.Error || HeaderPageView.Error || ConstFixedSlots.Error;
        pub const Slot = NodeSlotImpl;
        pub const PageHeader = HeaderPageView.PageHeader;

        page_view: HeaderPageView,

        pub fn init(data: DataType) Self {
            return .{ .page_view = HeaderPageView.init(data) };
        }

        pub fn formatPage(self: *Self, kind: u16, page_id: PageIdT, layout_id: u32) Error!void {
            if (read_only) {
                @compileError("Cannot format a read-only node page");
            }
            self.page_view.formatPage(
                kind,
                page_id,
                @as(IndexT, @intCast(@sizeOf(NodePageSubheader))),
                0,
            );
            self.subheaderMut().formatHeader(layout_id, @as(IndexT, @intCast(slot_size)));
            var slots_dir = try self.slotsMut();
            try slots_dir.format(slot_size);
        }

        pub fn validatePage(self: *const Self, page_id: PageIdT, kind: u16, layout_id: u32) Error!void {
            try self.page_view.validateTyped();
            const page_header = self.page_view.header();
            if (page_header.self_pid.get() != page_id or page_header.kind.get() != kind or
                @as(usize, @intCast(page_header.subheader_size.get())) != @sizeOf(NodePageSubheader) or
                page_header.metadata_size.get() != 0)
            {
                return Error.BadData;
            }
            const node_page_subheader = self.subheader();
            if (node_page_subheader.format_version != OrthtreePage.node_page_format_version or
                node_page_subheader.reserved != 0 or
                node_page_subheader.layout_id.get() != layout_id or
                @as(usize, @intCast(node_page_subheader.slot_size.get())) != slot_size or
                node_page_subheader.fsm_location.page_id.isMax() != node_page_subheader.fsm_location.slot_id.isMax())
            {
                return Error.BadData;
            }
            const slots_dir = try self.slots();
            if (try slots_dir.slotSize() != slot_size) {
                return Error.BadData;
            }
        }

        pub fn header(self: *const Self) *const PageHeader {
            return self.page_view.header();
        }

        pub fn headerMut(self: *Self) *PageHeader {
            if (read_only) {
                @compileError("Cannot get a mutable header from a read-only node page");
            }
            return self.page_view.headerMut();
        }

        pub fn subheader(self: *const Self) *const NodePageSubheader {
            const bytes = self.page_view.subheader();
            return @ptrCast(@alignCast(bytes.ptr));
        }

        pub fn subheaderMut(self: *Self) *NodePageSubheader {
            if (read_only) {
                @compileError("Cannot get a mutable node page subheader from a read-only view");
            }
            const bytes = self.page_view.subheaderMut();
            return @ptrCast(@alignCast(bytes.ptr));
        }

        pub fn slots(self: *const Self) Error!ConstFixedSlots {
            return try ConstFixedSlots.init(self.page_view.data());
        }

        pub fn slotsMut(self: *Self) Error!FixedSlots {
            if (read_only) {
                @compileError("Cannot get mutable slots from a read-only node page");
            }
            return try FixedSlots.init(self.page_view.dataMut());
        }

        pub fn slot(self: *const Self, slot_id: usize) Error!NodeSlotImpl {
            const slots_dir = try self.slots();
            return NodeSlotImpl.init(try slots_dir.get(slot_id));
        }

        pub fn slotMut(self: *Self, slot_id: usize) Error!NodeSlotImpl {
            if (read_only) {
                @compileError("Cannot get a mutable node slot from a read-only node page");
            }
            var slots_dir = try self.slotsMut();
            return NodeSlotImpl.init(try slots_dir.getMut(slot_id));
        }

        pub fn allocateSlot(self: *Self) Error!?usize {
            if (read_only) {
                @compileError("Cannot allocate a slot in a read-only node page");
            }
            var slots_dir = try self.slotsMut();
            const slot_id = try slots_dir.getFirstFree() orelse return null;
            try slots_dir.markUsed(slot_id);
            return slot_id;
        }

        pub fn freeSlots(self: *const Self) Error!usize {
            const slots_dir = try self.slots();
            return (try slots_dir.capacity()) - (try slots_dir.size());
        }
    };

    return struct {
        pub const NodePage = NodePageImpl;
        pub const NodeSlot = NodeSlotImpl;
        pub const Box = Key;
        pub const Trait = TraitStorageT;
        pub const node_slot_size = slot_size;
    };
}
