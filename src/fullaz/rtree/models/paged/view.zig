const std = @import("std");
const header = @import("../../../page/header.zig");
const slots = @import("../../../slots/variadic.zig");
const errors = @import("../../../core/errors.zig");
const rtree_page = @import("../../../page/rtree.zig");
const geometry = @import("../../geometry.zig");

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

    const ErrorSet = errors.PageError || errors.SlotsError;

    const Key = geometry.BoundingBox(CoordT, dims);

    const Mbr = RtreePage.Mbr;
    const LeafSlotHeaderType = RtreePage.LeafSlotHeader;
    const InodeSlotHeaderType = RtreePage.InodeSlotHeader;

    const leaf_header_size = @sizeOf(LeafSlotHeaderType);
    const inode_slot_size = @sizeOf(InodeSlotHeaderType);

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

        pub fn getMbr(self: *const Self, pos: usize) ErrorSet!Key {
            const buffer = try (try self.slotsDir()).get(pos);
            const slot: *const LeafSlotHeaderType = @ptrCast(@alignCast(&buffer[0]));
            return decodeMbr(&slot.mbr);
        }

        pub fn getValue(self: *const Self, pos: usize) ErrorSet![]const u8 {
            const buffer = try (try self.slotsDir()).get(pos);
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

        pub fn getMbr(self: *const Self, pos: usize) ErrorSet!Key {
            const buffer = try (try self.slotsDir()).get(pos);
            const slot: *const InodeSlotHeaderType = @ptrCast(@alignCast(&buffer[0]));
            return decodeMbr(&slot.mbr);
        }

        pub fn getChild(self: *const Self, pos: usize) ErrorSet!PageIdT {
            const buffer = try (try self.slotsDir()).get(pos);
            const slot: *const InodeSlotHeaderType = @ptrCast(@alignCast(&buffer[0]));
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
            var sd = try self.slotsDirMut();
            const buffer = try sd.reserveGetAt(sd.size(), inode_slot_size);
            const slot: *InodeSlotHeaderType = @ptrCast(@alignCast(&buffer[0]));
            slot.child.set(child);
            encodeMbr(&slot.mbr, mbr);
        }

        pub fn updateChildMbr(self: *Self, pos: usize, mbr: Key) ErrorSet!void {
            var sd = try self.slotsDirMut();
            const buffer = try sd.getMut(pos);
            const slot: *InodeSlotHeaderType = @ptrCast(@alignCast(&buffer[0]));
            encodeMbr(&slot.mbr, mbr);
        }

        pub fn compact(self: *Self, tmp_buf: []u8) ErrorSet!void {
            var sd = try self.slotsDirMut();
            sd.compactWithBuffer(tmp_buf) catch {
                try sd.compactInPlace();
            };
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

        pub fn setLevel(self: *Self, level: usize) void {
            self.subheaderMut().level.set(@as(IndexT, @intCast(level)));
        }
    };

    return struct {
        pub const Error = ErrorSet;
        pub const KeyType = Key;
        pub const PageViewType = HeaderPageView;
        pub const SlotsAvailableStatus = AvailableStatus;

        pub const LeafSubheaderView = LeafSubheaderViewType;
        pub const InodeSubheaderView = InodeSubheaderViewType;
    };
}
