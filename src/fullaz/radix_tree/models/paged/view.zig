const std = @import("std");
const radix_tree_page = @import("../../../page/radix_tree.zig");
const header = @import("../../../page/header.zig");
const slots = @import("../../../slots/slots.zig");
const errors = @import("../../../core/errors.zig");
const algorithm = @import("../../../core/algorithm.zig");

pub fn View(comptime PageIdT: type, comptime IndexT: type, comptime KeyT: type, comptime ValueSize: usize, comptime Endian: std.builtin.Endian, comptime read_only: bool) type {
    const RadixTreePage = radix_tree_page.RadixTree(PageIdT, IndexT, KeyT, Endian);

    const HeaderPageView = header.View(PageIdT, IndexT, Endian, read_only);
    const SlotsDirType = slots.Fixed(u16, IndexT, Endian, read_only);
    const ConstSlotsDirType = slots.Fixed(u16, IndexT, Endian, true);

    const ErrorSet = errors.BufferError ||
        errors.OrderError ||
        errors.PageError ||
        errors.SlotsError;

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

        pub fn check(self: *const Self) ErrorSet!void {
            const slols = try self.slotsDir();
            if (try slols.slotSize() != ValueSize) {
                return ErrorSet.BadData;
            }
        }

        pub fn formatPage(self: *Self, kind: u16, page_id: PageIdT, metadata_len: IndexT) ErrorSet!void {
            const subheader_size = @as(IndexT, @intCast(@sizeOf(SubheaderType)));
            self.page_view.formatPage(kind, page_id, subheader_size, metadata_len);
            const data = self.page_view.dataMut();
            var sl = try SlotsDirType.init(data);
            self.subheaderMut().formatHeader();
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

        pub fn slotsCapacity(self: *const Self) ErrorSet!usize {
            const slols = try self.slotsDir();
            return try slols.capacity();
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

        pub fn check(self: *const Self) ErrorSet!void {
            const slols = try self.slotsDir();
            if (try slols.slotSize() != @sizeOf(SlotType)) {
                return ErrorSet.BadData;
            }
        }

        pub fn formatPage(self: *Self, kind: u16, page_id: PageIdT, metadata_len: IndexT) ErrorSet!void {
            const subheader_size = @as(IndexT, @intCast(@sizeOf(SubheaderType)));
            self.page_view.formatPage(kind, page_id, subheader_size, metadata_len);
            const data = self.page_view.dataMut();
            var sl = try SlotsDirType.init(data);
            self.subheaderMut().formatHeader();
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

        pub fn slotsCapacity(self: *const Self) ErrorSet!usize {
            const slols = try self.slotsDir();
            return try slols.capacity();
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
