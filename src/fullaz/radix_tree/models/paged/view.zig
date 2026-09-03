const std = @import("std");
const radix_tree_page = @import("../../../page/radix_tree.zig");
const header = @import("../../../page/header.zig");
const slots = @import("../../../slots/slots.zig");
const errors = @import("../../../core/errors.zig");
const algorithm = @import("../../../core/algorithm.zig");

pub fn View(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime KeyT: type,
    comptime ValueSize: usize,
    comptime Endian: std.builtin.Endian,
    comptime read_only: bool,
) type {
    const RadixTreePage = radix_tree_page.RadixTree(PageIdT, IndexT, KeyT, Endian);

    const HeaderPageView = header.View(PageIdT, IndexT, Endian, read_only);
    const SlotsDirType = slots.Fixed(u16, IndexT, Endian, read_only);
    const ConstSlotsDirType = slots.Fixed(u16, IndexT, Endian, true);

    const ErrorSet = errors.BufferError ||
        errors.OrderError ||
        errors.PageError ||
        errors.SlotsError ||
        header.ValidationError;

    const LeafSubheaderType = RadixTreePage.LeafSubheader;
    const InodeSubheaderType = RadixTreePage.InodeSubheader;
    const InodeSlotType = RadixTreePage.InodeSlot;

    const LeafSubheaderViewType = struct {
        const Self = @This();
        const SubheaderType = LeafSubheaderType;
        const ValueType = []const u8;
        const DataType = if (read_only) []const u8 else []u8;
        const PageViewType = HeaderPageView;

        page_view: PageViewType,

        pub fn init(data: DataType) Self {
            return .{
                .page_view = PageViewType.init(data),
            };
        }

        pub fn calculateSlotCapacity(page_size: usize, metadata_len: usize) usize {
            const header_size = PageViewType.header_size + @sizeOf(SubheaderType);
            const available_space = page_size - header_size - metadata_len;
            return SlotsDirType.maxObjectsByWords(available_space, ValueSize).objects;
        }

        pub fn check(self: *const Self) ErrorSet!void {
            try self.page_view.validateTyped();
            if (self.page_view.header().subheader_size.get() != @sizeOf(SubheaderType)) {
                return ErrorSet.BadData;
            }
            const slols = try self.slotsDir();
            try slols.validate();
            if (try slols.slotSize() != ValueSize) {
                return ErrorSet.BadData;
            }
        }

        pub fn validatePage(self: *const Self, page_id: PageIdT, kind: u16) ErrorSet!void {
            try self.check();
            const page_header = self.page_view.header();
            if (page_id == std.math.maxInt(PageIdT) or page_header.self_pid.get() != page_id or
                page_header.kind.get() != kind or page_header.metadata_size.get() != 0)
            {
                return ErrorSet.BadData;
            }
        }

        pub fn formatPage(self: *Self, kind: u16, page_id: PageIdT, metadata_len: IndexT) ErrorSet!void {
            const subheader_size = @as(IndexT, @intCast(@sizeOf(SubheaderType)));
            self.page_view.formatPage(kind, page_id, subheader_size, metadata_len);
            const data = self.page_view.dataMut();
            var sl = try SlotsDirType.init(data);
            var sub_hdr = self.subheaderMut();

            sub_hdr.formatHeader();
            sub_hdr.parent.setMax();
            sub_hdr.parent_quotient.set(0);
            sub_hdr.parent_idx.set(0);

            try sl.format(ValueSize);
        }

        pub fn subheader(self: *const Self) *const SubheaderType {
            const subhdr = self.page_view.subheader();
            return @ptrCast(@alignCast(&subhdr[0]));
        }

        pub fn subheaderMut(self: *Self) *SubheaderType {
            if (read_only) {
                @compileError("Cannot get mutable subheader from a read-only page");
            }
            const subhdr = self.page_view.subheaderMut();
            return @ptrCast(@alignCast(&subhdr[0]));
        }

        pub fn page(self: *const Self) DataType {
            return self.page_view.page;
        }

        pub fn slotsDirMut(self: *Self) ErrorSet!SlotsDirType {
            const data = self.page_view.dataMut();
            return try SlotsDirType.init(data);
        }

        pub fn slotsDir(self: *const Self) ErrorSet!ConstSlotsDirType {
            const data = self.page_view.data();
            return try ConstSlotsDirType.init(data);
        }

        pub fn slotSize(self: *const Self) ErrorSet!usize {
            const slols = try self.slotsDir();
            return try slols.slotSize();
        }

        pub fn size(self: *const Self) ErrorSet!usize {
            const slols = try self.slotsDir();
            return try slols.size();
        }

        pub fn capacity(self: *const Self) ErrorSet!usize {
            const slot_dir = try self.slotsDir();
            return try slot_dir.capacity();
        }

        pub fn set(self: *Self, key: KeyT, value: []const u8) ErrorSet!void {
            var slot_dir = try self.slotsDirMut();
            const slot_index = std.math.cast(usize, key) orelse return error.OutOfBounds;
            try slot_dir.set(slot_index, value);
        }

        pub fn get(self: *const Self, key: KeyT) ErrorSet![]const u8 {
            const slot_dir = try self.slotsDir();
            const slot_index = std.math.cast(usize, key) orelse return error.OutOfBounds;
            return try slot_dir.get(slot_index);
        }

        pub fn valueMut(self: *Self, key: KeyT) ErrorSet![]u8 {
            var slot_dir = try self.slotsDirMut();
            const slot_index = std.math.cast(usize, key) orelse return error.OutOfBounds;
            return try slot_dir.getMut(slot_index);
        }

        pub fn isSet(self: *const Self, key: KeyT) ErrorSet!bool {
            const slot_dir = try self.slotsDir();
            const slot_index = std.math.cast(usize, key) orelse return error.OutOfBounds;
            return try slot_dir.isSet(slot_index);
        }

        pub fn free(self: *Self, key: KeyT) ErrorSet!void {
            var slot_dir = try self.slotsDirMut();
            const slot_index = std.math.cast(usize, key) orelse return error.OutOfBounds;
            try slot_dir.free(slot_index);
        }

        pub fn getFirstFree(self: *const Self) ErrorSet!?KeyT {
            const slot_dir = try self.slotsDir();
            const index = try slot_dir.getFirstFree() orelse return null;
            return @intCast(index);
        }

        pub fn isInFree(self: *const Self) ErrorSet!bool {
            const subheader_view = self.subheader();
            const value = subheader_view.on_free_list;
            if (value > 1) {
                return ErrorSet.BadData;
            }
            return value == 1;
        }

        const FreeLeafLinks = struct {
            prev: ?PageIdT,
            next: ?PageIdT,
        };

        fn getFreeLeafLinks(self: *const Self) ErrorSet!FreeLeafLinks {
            const subheader_view = self.subheader();
            const listed = try self.isInFree();
            const prev = if (subheader_view.free_leaf_links.prev.isMax())
                null
            else
                subheader_view.free_leaf_links.prev.get();
            const next = if (subheader_view.free_leaf_links.next.isMax())
                null
            else
                subheader_view.free_leaf_links.next.get();
            const self_id = self.page_view.header().self_pid.get();
            if ((!listed and (prev != null or next != null)) or
                (prev != null and prev.? == self_id) or
                (next != null and next.? == self_id))
            {
                return ErrorSet.BadData;
            }
            return .{ .prev = prev, .next = next };
        }

        pub fn getPrevFreeLeaf(self: *const Self) ErrorSet!?PageIdT {
            return (try self.getFreeLeafLinks()).prev;
        }

        pub fn getNextFreeLeaf(self: *const Self) ErrorSet!?PageIdT {
            return (try self.getFreeLeafLinks()).next;
        }

        pub fn setFreeLeafLinks(self: *Self, prev: ?PageIdT, next: ?PageIdT) ErrorSet!void {
            var subheader_view = self.subheaderMut();
            subheader_view.on_free_list = 1;
            if (prev) |id| {
                subheader_view.free_leaf_links.prev.set(id);
            } else {
                subheader_view.free_leaf_links.prev.setMax();
            }
            if (next) |id| {
                subheader_view.free_leaf_links.next.set(id);
            } else {
                subheader_view.free_leaf_links.next.setMax();
            }
        }

        pub fn setPrevFreeLeaf(self: *Self, page_id: ?PageIdT) ErrorSet!void {
            if (!try self.isInFree()) {
                return ErrorSet.BadData;
            }
            var subheader_view = self.subheaderMut();
            if (page_id) |id| {
                subheader_view.free_leaf_links.prev.set(id);
            } else {
                subheader_view.free_leaf_links.prev.setMax();
            }
        }

        pub fn setNextFreeLeaf(self: *Self, page_id: ?PageIdT) ErrorSet!void {
            if (!try self.isInFree()) {
                return ErrorSet.BadData;
            }
            var subheader_view = self.subheaderMut();
            if (page_id) |id| {
                subheader_view.free_leaf_links.next.set(id);
            } else {
                subheader_view.free_leaf_links.next.setMax();
            }
        }

        pub fn clearFreeLeaf(self: *Self) void {
            var subheader_view = self.subheaderMut();
            subheader_view.on_free_list = 0;
            subheader_view.free_leaf_links.prev.setMax();
            subheader_view.free_leaf_links.next.setMax();
        }

        pub fn setParent(self: *Self, parent_id: ?PageIdT) ErrorSet!void {
            var sub_hdr = self.subheaderMut();
            if (parent_id) |pid| {
                sub_hdr.parent.set(pid);
            } else {
                sub_hdr.parent.setMax();
            }
        }

        pub fn getParent(self: *const Self) ErrorSet!?PageIdT {
            var sub_hdr = self.subheader();
            if (sub_hdr.parent.isMax()) {
                return null;
            } else {
                return sub_hdr.parent.get();
            }
        }

        pub fn setParentQuotient(self: *Self, quotient: KeyT) ErrorSet!void {
            var sub_hdr = self.subheaderMut();
            sub_hdr.parent_quotient.set(quotient);
        }

        pub fn getParentQuotient(self: *const Self) ErrorSet!KeyT {
            var sub_hdr = self.subheader();
            return sub_hdr.parent_quotient.get();
        }

        pub fn setParentIdx(self: *Self, idx: KeyT) ErrorSet!void {
            var sub_hdr = self.subheaderMut();
            sub_hdr.parent_idx.set(@as(u16, @intCast(idx)));
        }

        pub fn getParentIdx(self: *const Self) ErrorSet!KeyT {
            var sub_hdr = self.subheader();
            return @as(KeyT, sub_hdr.parent_idx.get());
        }
    };

    const InodeSubheaderViewType = struct {
        const Self = @This();

        const SubheaderType = InodeSubheaderType;
        const ValueType = []const u8;
        const DataType = if (read_only) []const u8 else []u8;
        const PageViewType = HeaderPageView;
        const SlotType = InodeSlotType;

        page_view: PageViewType,

        pub fn init(data: DataType) Self {
            return .{
                .page_view = PageViewType.init(data),
            };
        }

        pub fn calculateSlotCapacity(page_size: usize, metadata_len: usize) usize {
            const header_size = PageViewType.header_size + @sizeOf(SubheaderType);
            const available_space = page_size - header_size - metadata_len;
            return SlotsDirType.maxObjectsByWords(available_space, @sizeOf(SlotType)).objects;
        }

        pub fn check(self: *const Self) ErrorSet!void {
            try self.page_view.validateTyped();
            if (self.page_view.header().subheader_size.get() != @sizeOf(SubheaderType)) {
                return ErrorSet.BadData;
            }
            const slols = try self.slotsDir();
            try slols.validate();
            if (try slols.slotSize() != @sizeOf(SlotType)) {
                return ErrorSet.BadData;
            }
        }

        pub fn validatePage(self: *const Self, page_id: PageIdT, kind: u16) ErrorSet!void {
            try self.check();
            const page_header = self.page_view.header();
            if (page_id == std.math.maxInt(PageIdT) or page_header.self_pid.get() != page_id or
                page_header.kind.get() != kind or page_header.metadata_size.get() != 0)
            {
                return ErrorSet.BadData;
            }
        }

        pub fn getAt(self: *const Self, pos: usize) ErrorSet!PageIdT {
            const slot_dir = try self.slotsDir();
            const value_as_bytes = try slot_dir.get(pos);
            if (value_as_bytes.len != @sizeOf(SlotType)) {
                return ErrorSet.BadData;
            }
            var slot: SlotType = undefined;
            @memcpy(std.mem.asBytes(&slot), value_as_bytes);
            return slot.child.get();
        }

        pub fn formatPage(self: *Self, kind: u16, page_id: PageIdT, metadata_len: IndexT) ErrorSet!void {
            const subheader_size = @as(IndexT, @intCast(@sizeOf(SubheaderType)));
            self.page_view.formatPage(kind, page_id, subheader_size, metadata_len);
            const data = self.page_view.dataMut();
            var sl = try SlotsDirType.init(data);
            var sub_hdr = self.subheaderMut();

            sub_hdr.formatHeader();
            sub_hdr.parent.setMax();
            sub_hdr.parent_quotient.set(0);
            sub_hdr.parent_idx.set(0);

            try sl.format(@sizeOf(SlotType));
        }

        pub fn subheader(self: *const Self) *const SubheaderType {
            const subhdr = self.page_view.subheader();
            return @ptrCast(@alignCast(&subhdr[0]));
        }

        pub fn subheaderMut(self: *Self) *SubheaderType {
            if (read_only) {
                @compileError("Cannot get mutable subheader from a read-only page");
            }
            const subhdr = self.page_view.subheaderMut();
            return @ptrCast(@alignCast(&subhdr[0]));
        }

        pub fn page(self: *const Self) DataType {
            return self.page_view.page;
        }

        pub fn slotsDirMut(self: *Self) ErrorSet!SlotsDirType {
            const data = self.page_view.dataMut();
            return try SlotsDirType.init(data);
        }

        pub fn slotsDir(self: *const Self) ErrorSet!ConstSlotsDirType {
            const data = self.page_view.data();
            return try ConstSlotsDirType.init(data);
        }

        pub fn slotSize(self: *const Self) ErrorSet!usize {
            const slols = try self.slotsDir();
            return try slols.slotSize();
        }

        pub fn size(self: *const Self) ErrorSet!usize {
            const slols = try self.slotsDir();
            return try slols.size();
        }

        pub fn capacity(self: *const Self) ErrorSet!usize {
            const slols = try self.slotsDir();
            return try slols.capacity();
        }

        pub fn set(self: *Self, key: KeyT, value: PageIdT) ErrorSet!void {
            var slot_dir = try self.slotsDirMut();
            var slot = SlotType{ .child = undefined };
            slot.child.set(value);
            const slot_index = std.math.cast(usize, key) orelse return error.OutOfBounds;
            try slot_dir.set(slot_index, std.mem.asBytes(&slot));
        }

        pub fn get(self: *const Self, key: KeyT) ErrorSet!PageIdT {
            const slot_dir = try self.slotsDir();
            const slot_index = std.math.cast(usize, key) orelse return error.OutOfBounds;
            const value_as_bytes = try slot_dir.get(slot_index);
            if (value_as_bytes.len != @sizeOf(PageIdT)) {
                return ErrorSet.BadData;
            }
            var slot: SlotType = undefined;
            @memcpy(std.mem.asBytes(&slot), value_as_bytes);
            return slot.child.get();
        }

        pub fn isSet(self: *const Self, key: KeyT) ErrorSet!bool {
            const slot_dir = try self.slotsDir();
            const slot_index = std.math.cast(usize, key) orelse return error.OutOfBounds;
            return try slot_dir.isSet(slot_index);
        }

        pub fn free(self: *Self, key: KeyT) ErrorSet!void {
            var slot_dir = try self.slotsDirMut();
            const slot_index = std.math.cast(usize, key) orelse return error.OutOfBounds;
            try slot_dir.free(slot_index);
        }

        pub fn setParent(self: *Self, parent_id: ?PageIdT) ErrorSet!void {
            var sub_hdr = self.subheaderMut();
            if (parent_id) |pid| {
                sub_hdr.parent.set(pid);
            } else {
                sub_hdr.parent.setMax();
            }
        }

        pub fn getParent(self: *const Self) ErrorSet!?PageIdT {
            var sub_hdr = self.subheader();
            if (sub_hdr.parent.isMax()) {
                return null;
            } else {
                return sub_hdr.parent.get();
            }
        }

        pub fn setParentQuotient(self: *Self, quotient: KeyT) ErrorSet!void {
            var sub_hdr = self.subheaderMut();
            sub_hdr.parent_quotient.set(quotient);
        }

        pub fn getParentQuotient(self: *const Self) ErrorSet!KeyT {
            var sub_hdr = self.subheader();
            return sub_hdr.parent_quotient.get();
        }

        pub fn setParentIdx(self: *Self, idx: KeyT) ErrorSet!void {
            var sub_hdr = self.subheaderMut();
            sub_hdr.parent_idx.set(@as(u16, @intCast(idx)));
        }

        pub fn getParentIdx(self: *const Self) ErrorSet!KeyT {
            var sub_hdr = self.subheader();
            return @as(KeyT, sub_hdr.parent_idx.get());
        }

        pub fn setLevel(self: *Self, level: usize) ErrorSet!void {
            var sub_hdr = self.subheaderMut();
            if (level > std.math.maxInt(u8)) {
                return ErrorSet.BadData;
            }
            sub_hdr.level.set(@as(u8, @intCast(level)));
        }

        pub fn getLevel(self: *const Self) ErrorSet!usize {
            var sub_hdr = self.subheader();
            return @as(usize, sub_hdr.level.get());
        }
    };

    return struct {
        const Self = @This();
        pub const Slots = SlotsDirType;

        pub const Error = ErrorSet;

        pub const PageViewType = HeaderPageView;

        pub const LeafSubheader = LeafSubheaderType;
        pub const InodeSubheader = InodeSubheaderType;

        pub const LeafSubheaderView = LeafSubheaderViewType;
        pub const InodeSubheaderView = InodeSubheaderViewType;
    };
}
