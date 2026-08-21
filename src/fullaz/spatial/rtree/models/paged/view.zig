const std = @import("std");
const build_options = @import("build_options");
const header = @import("../../../../page/header.zig");
const slots = @import("../../../../slots/variadic.zig");
const errors = @import("../../../../core/errors.zig");
const rtree_page = @import("../../../../page/rtree.zig");
const geometry = @import("../../../geometry.zig");
const limits = @import("../../limits.zig");

pub fn View(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime CoordT: type,
    comptime dims: usize,
    comptime Endian: std.builtin.Endian,
    comptime read_only: bool,
) type {
    const RtreePage = rtree_page.Rtree(PageIdT, IndexT, CoordT, dims, Endian);

    const HeaderPageView = header.View(PageIdT, IndexT, Endian, read_only);
    const SlotsDirType = slots.Variadic(IndexT, Endian, read_only);
    const ConstSlotsDirType = slots.Variadic(IndexT, Endian, true);

    const AvailableStatus = ConstSlotsDirType.AvailableStatus;

    const ErrorSet = HeaderPageView.Error || errors.PageError || errors.SlotsError;

    const Key = geometry.BoundingBox(CoordT, dims);

    const Mbr = RtreePage.Mbr;
    const LeafSlotHeaderType = RtreePage.LeafSlotHeader;
    const InodeSlotHeaderType = RtreePage.InodeSlotHeader;

    const leaf_header_size = @sizeOf(LeafSlotHeaderType);
    const inode_slot_size = @sizeOf(InodeSlotHeaderType);

    const validatePageHeader = struct {
        fn call(
            page_view: *const HeaderPageView,
            page_id: PageIdT,
            kind: u16,
            subheader_size: usize,
        ) ErrorSet!void {
            try page_view.validateTyped();
            const page_header = page_view.header();
            if (page_id == std.math.maxInt(PageIdT) or page_header.self_pid.get() != page_id) {
                return ErrorSet.BadData;
            }
            if (page_header.kind.get() != kind) {
                return ErrorSet.BadType;
            }
            if (@as(usize, @intCast(page_header.subheader_size.get())) != subheader_size or
                page_header.metadata_size.get() != 0)
            {
                return ErrorSet.BadData;
            }
        }
    }.call;

    const encodeMbr = struct {
        fn call(dst: *Mbr, box: Key) void {
            inline for (0..dims) |i| {
                dst.low[i].set(box.low[i]);
                dst.high[i].set(box.high[i]);
            }
        }
    }.call;

    const decodeMbr = struct {
        fn call(src: *const Mbr) Key {
            var box = Key.init();
            inline for (0..dims) |i| {
                box.low[i] = src.low[i].get();
                box.high[i] = src.high[i].get();
            }
            return box;
        }
    }.call;

    const LeafSubheaderViewType = struct {
        const Self = @This();
        const DataType = if (read_only) []const u8 else []u8;

        const SubheaderType = RtreePage.LeafSubheader;

        page_view: HeaderPageView,

        pub fn init(data: DataType) Self {
            return .{ .page_view = HeaderPageView.init(data) };
        }

        pub fn formatPage(self: *Self, kind: u16, page_id: PageIdT, metadata_len: IndexT) ErrorSet!void {
            self.page_view.formatPage(kind, page_id, @as(IndexT, @intCast(@sizeOf(SubheaderType))), metadata_len);
            var sl = try SlotsDirType.init(self.page_view.dataMut());
            sl.formatHeader();
            self.subheaderMut().formatHeader();
        }

        pub fn subheader(self: *const Self) *const SubheaderType {
            const subhdr = self.page_view.subheader();
            return @ptrCast(@alignCast(&subhdr[0]));
        }

        pub fn subheaderMut(self: *Self) *SubheaderType {
            if (read_only) @compileError("Cannot get mutable subheader from a read-only page");
            const subhdr = self.page_view.subheaderMut();
            return @ptrCast(@alignCast(&subhdr[0]));
        }

        pub fn slotsDir(self: *const Self) ErrorSet!ConstSlotsDirType {
            return try ConstSlotsDirType.init(self.page_view.data());
        }

        pub fn slotsDirMut(self: *Self) ErrorSet!SlotsDirType {
            return try SlotsDirType.init(self.page_view.dataMut());
        }

        pub fn entries(self: *const Self) ErrorSet!usize {
            return (try self.slotsDir()).size();
        }

        pub fn validatePage(
            self: *const Self,
            page_id: PageIdT,
            kind: u16,
            max_entries: usize,
            max_value_size: usize,
        ) ErrorSet!void {
            try validatePageHeader(&self.page_view, page_id, kind, @sizeOf(SubheaderType));

            const slot_dir = try self.slotsDir();
            try slot_dir.validateStructural();
            const count = slot_dir.size();
            if (count > max_entries) {
                return ErrorSet.BadData;
            }

            var index: usize = 0;
            while (index < count) : (index += 1) {
                const slot = try slot_dir.get(index);
                if (slot.len < leaf_header_size or slot.len - leaf_header_size > max_value_size) {
                    return ErrorSet.BadData;
                }
            }

            if (build_options.full_validation) {
                try slot_dir.validate();
            }
        }

        pub fn getMbr(self: *const Self, pos: usize) ErrorSet!Key {
            const buffer = try (try self.slotsDir()).get(pos);
            if (buffer.len < leaf_header_size) {
                return ErrorSet.BadData;
            }
            const slot: *const LeafSlotHeaderType = @ptrCast(@alignCast(&buffer[0]));
            return decodeMbr(&slot.mbr);
        }

        pub fn getValue(self: *const Self, pos: usize) ErrorSet![]const u8 {
            const buffer = try (try self.slotsDir()).get(pos);
            if (buffer.len < leaf_header_size) {
                return ErrorSet.BadData;
            }
            return buffer[leaf_header_size..];
        }

        pub fn nodeMbr(self: *const Self) ErrorSet!Key {
            const sd = try self.slotsDir();
            const n = sd.size();
            if (n == 0) return Key.init();
            var acc = try self.getMbr(0);
            var i: usize = 1;
            while (i < n) : (i += 1) {
                const m = try self.getMbr(i);
                acc = acc.merged(&m);
            }
            return acc;
        }

        pub fn canAppend(self: *const Self, value_len: usize) ErrorSet!AvailableStatus {
            return (try self.slotsDir()).canInsert(leaf_header_size + value_len);
        }

        pub fn append(self: *Self, mbr: Key, value: []const u8) ErrorSet!void {
            var sd = try self.slotsDirMut();
            const buffer = try sd.reserveGetAt(sd.size(), leaf_header_size + value.len);
            const slot: *LeafSlotHeaderType = @ptrCast(@alignCast(&buffer[0]));
            encodeMbr(&slot.mbr, mbr);
            @memcpy(buffer[leaf_header_size..][0..value.len], value);
        }

        pub fn compact(self: *Self, tmp_buf: []u8) ErrorSet!void {
            var sd = try self.slotsDirMut();
            sd.compactWithBuffer(tmp_buf) catch {
                try sd.compactInPlace();
            };
        }

        pub fn compactInPlace(self: *Self) ErrorSet!void {
            var sd = try self.slotsDirMut();
            try sd.compactInPlace();
        }

        pub fn erase(self: *Self, pos: usize) ErrorSet!void {
            var sd = try self.slotsDirMut();
            return sd.remove(pos);
        }

        pub fn clear(self: *Self) ErrorSet!void {
            var sd = try self.slotsDirMut();
            sd.formatHeader();
        }

        pub fn capacityFor(self: *const Self, value_len: usize) ErrorSet!usize {
            return (try self.slotsDir()).capacityFor(leaf_header_size + value_len);
        }
    };

    const InodeSubheaderViewType = struct {
        const Self = @This();
        const DataType = if (read_only) []const u8 else []u8;

        const SubheaderType = RtreePage.InodeSubheader;

        page_view: HeaderPageView,

        pub fn init(data: DataType) Self {
            return .{ .page_view = HeaderPageView.init(data) };
        }

        pub fn formatPage(self: *Self, kind: u16, page_id: PageIdT, metadata_len: IndexT) ErrorSet!void {
            self.page_view.formatPage(kind, page_id, @as(IndexT, @intCast(@sizeOf(SubheaderType))), metadata_len);
            var sl = try SlotsDirType.init(self.page_view.dataMut());
            sl.formatHeader();
            self.subheaderMut().formatHeader();
        }

        pub fn subheader(self: *const Self) *const SubheaderType {
            const subhdr = self.page_view.subheader();
            return @ptrCast(@alignCast(&subhdr[0]));
        }

        pub fn subheaderMut(self: *Self) *SubheaderType {
            if (read_only) @compileError("Cannot get mutable subheader from a read-only page");
            const subhdr = self.page_view.subheaderMut();
            return @ptrCast(@alignCast(&subhdr[0]));
        }

        pub fn slotsDir(self: *const Self) ErrorSet!ConstSlotsDirType {
            return try ConstSlotsDirType.init(self.page_view.data());
        }

        pub fn slotsDirMut(self: *Self) ErrorSet!SlotsDirType {
            return try SlotsDirType.init(self.page_view.dataMut());
        }

        pub fn entries(self: *const Self) ErrorSet!usize {
            return (try self.slotsDir()).size();
        }

        pub fn validatePage(
            self: *const Self,
            page_id: PageIdT,
            kind: u16,
            max_entries: usize,
        ) ErrorSet!void {
            try validatePageHeader(&self.page_view, page_id, kind, @sizeOf(SubheaderType));
            if (self.getLevel() == 0 or self.getLevel() >= limits.max_depth) {
                return ErrorSet.BadData;
            }

            const slot_dir = try self.slotsDir();
            try slot_dir.validateStructural();
            const count = slot_dir.size();
            if (count > max_entries) {
                return ErrorSet.BadData;
            }

            var index: usize = 0;
            while (index < count) : (index += 1) {
                const slot = try slot_dir.get(index);
                if (slot.len != inode_slot_size) {
                    return ErrorSet.BadData;
                }
                const inode_slot: *const InodeSlotHeaderType = @ptrCast(@alignCast(&slot[0]));
                if (inode_slot.child.isMax()) {
                    return ErrorSet.BadData;
                }
            }

            if (build_options.full_validation) {
                try slot_dir.validate();
            }
        }

        pub fn getMbr(self: *const Self, pos: usize) ErrorSet!Key {
            const buffer = try (try self.slotsDir()).get(pos);
            if (buffer.len != inode_slot_size) {
                return ErrorSet.BadData;
            }
            const slot: *const InodeSlotHeaderType = @ptrCast(@alignCast(&buffer[0]));
            return decodeMbr(&slot.mbr);
        }

        pub fn getChild(self: *const Self, pos: usize) ErrorSet!PageIdT {
            const buffer = try (try self.slotsDir()).get(pos);
            if (buffer.len != inode_slot_size) {
                return ErrorSet.BadData;
            }
            const slot: *const InodeSlotHeaderType = @ptrCast(@alignCast(&buffer[0]));
            if (slot.child.isMax()) {
                return ErrorSet.BadData;
            }
            return slot.child.get();
        }

        pub fn nodeMbr(self: *const Self) ErrorSet!Key {
            const sd = try self.slotsDir();
            const n = sd.size();
            if (n == 0) return Key.init();
            var acc = try self.getMbr(0);
            var i: usize = 1;
            while (i < n) : (i += 1) {
                const m = try self.getMbr(i);
                acc = acc.merged(&m);
            }
            return acc;
        }

        pub fn canAppend(self: *const Self) ErrorSet!AvailableStatus {
            return (try self.slotsDir()).canInsert(inode_slot_size);
        }

        pub fn append(self: *Self, mbr: Key, child: PageIdT) ErrorSet!void {
            if (child == std.math.maxInt(PageIdT)) {
                return ErrorSet.BadData;
            }
            var sd = try self.slotsDirMut();
            const buffer = try sd.reserveGetAt(sd.size(), inode_slot_size);
            const slot: *InodeSlotHeaderType = @ptrCast(@alignCast(&buffer[0]));
            slot.child.set(child);
            encodeMbr(&slot.mbr, mbr);
        }

        pub fn updateChildMbr(self: *Self, pos: usize, mbr: Key) ErrorSet!void {
            var sd = try self.slotsDirMut();
            const buffer = try sd.getMut(pos);
            if (buffer.len != inode_slot_size) {
                return ErrorSet.BadData;
            }
            const slot: *InodeSlotHeaderType = @ptrCast(@alignCast(&buffer[0]));
            encodeMbr(&slot.mbr, mbr);
        }

        pub fn compact(self: *Self, tmp_buf: []u8) ErrorSet!void {
            var sd = try self.slotsDirMut();
            sd.compactWithBuffer(tmp_buf) catch {
                try sd.compactInPlace();
            };
        }

        pub fn compactInPlace(self: *Self) ErrorSet!void {
            var sd = try self.slotsDirMut();
            try sd.compactInPlace();
        }

        pub fn erase(self: *Self, pos: usize) ErrorSet!void {
            var sd = try self.slotsDirMut();
            return sd.remove(pos);
        }

        pub fn clear(self: *Self) ErrorSet!void {
            var sd = try self.slotsDirMut();
            sd.formatHeader();
        }

        pub fn capacityFor(self: *const Self) ErrorSet!usize {
            return (try self.slotsDir()).capacityFor(inode_slot_size);
        }

        pub fn getLevel(self: *const Self) usize {
            return @as(usize, self.subheader().level.get());
        }

        pub fn setLevel(self: *Self, level: usize) ErrorSet!void {
            if (level == 0 or level >= limits.max_depth) {
                return ErrorSet.BadData;
            }
            const stored_level = std.math.cast(IndexT, level) orelse return ErrorSet.BadData;
            self.subheaderMut().level.set(stored_level);
        }
    };

    return struct {
        pub const Error = ErrorSet;
        pub const KeyType = Key;
        pub const PageViewType = HeaderPageView;
        pub const SlotsAvailableStatus = AvailableStatus;
        pub const full_validation_enabled = build_options.full_validation;

        pub const LeafSubheaderView = LeafSubheaderViewType;
        pub const InodeSubheaderView = InodeSubheaderViewType;
    };
}
