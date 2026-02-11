const std = @import("std");
const PackedInt = @import("../../../core/packed_int.zig").PackedInt;
const header = @import("../../../page/header.zig");
const slots = @import("../../../slots/variadic.zig");
const errors = @import("../../../core/errors.zig");
const wbpt_page = @import("../../../page/weighted_bpt.zig");
const algorithm = @import("../../../core/algorithm.zig");

pub fn View(comptime PageIdT: type, comptime IndexT: type, comptime Weight: type, comptime Endian: std.builtin.Endian, comptime read_only: bool) type {
    const WBptPage = wbpt_page.WeightedBpt(PageIdT, IndexT, Weight, Endian);

    const HeaderPageView = header.View(PageIdT, IndexT, Endian, read_only);
    const SlotsDirType = slots.Variadic(IndexT, Endian, read_only);
    const ConstSlotsDirType = slots.Variadic(IndexT, Endian, true);

    const AvailableStatus = ConstSlotsDirType.AvailableStatus;

    const ErrorSet = errors.BptError ||
        errors.OrderError ||
        errors.PageError ||
        errors.SlotsError;

    const LeafSubheaderType = WBptPage.LeafSubheader;
    const LeafSlotHeaderType = WBptPage.LeafSlotHeader;
    const LeafSubheaderViewType = struct {
        const Self = @This();

        const DataType = if (read_only) []const u8 else []u8;
        const PageViewType = HeaderPageView;

        const SubheaderType = LeafSubheaderType;
        const SlotHeaderType = LeafSlotHeaderType;

        const ValueType = []const u8;
        page_view: PageViewType,

        pub fn init(data: DataType) Self {
            return .{
                .page_view = PageViewType.init(data),
            };
        }

        pub fn formatPage(self: *Self, kind: u16, page_id: PageIdT, metadata_len: IndexT) ErrorSet!void {
            const subheader_size = @as(IndexT, @intCast(@sizeOf(SubheaderType)));
            self.page_view.formatPage(kind, page_id, subheader_size, metadata_len);
            const data = self.page_view.dataMut();
            var sl = try SlotsDirType.init(data);
            self.subheaderMut().formatHeader();
            sl.formatHeader();
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

        pub fn totalSlotSize(_: *const Self, value_len: usize) usize {
            return @sizeOf(SlotHeaderType) + value_len;
        }

        pub fn entries(self: *const Self) !usize {
            return (try self.slotsDir()).size();
        }

        pub fn slotsDirMut(self: *Self) ErrorSet!SlotsDirType {
            const data = self.page_view.dataMut();
            return try SlotsDirType.init(data);
        }

        pub fn slotsDir(self: *const Self) ErrorSet!ConstSlotsDirType {
            const data = self.page_view.data();
            return try ConstSlotsDirType.init(data);
        }

        pub fn capacityFor(self: *const Self, data_len: usize) ErrorSet!usize {
            const maximum_slot_size = data_len + @sizeOf(SlotHeaderType);
            return (try self.slotsDir()).capacityFor(maximum_slot_size);
        }

        pub fn canInsert(self: *const Self, value: []const u8) ErrorSet!AvailableStatus {
            const total_len = @sizeOf(SlotHeaderType) + value.len;
            return (try self.slotsDir()).canInsert(total_len);
        }
    };

    const InodeSubheaderType = WBptPage.InodeSubheader;
    const InodeSlotType = WBptPage.InodeSlot;
    const InodeSubheaderViewType = struct {
        const Self = @This();

        const DataType = if (read_only) []const u8 else []u8;
        const PageViewType = HeaderPageView;

        const SubheaderType = InodeSubheaderType;
        const SlotHeaderType = InodeSlotType;
    };

    return struct {
        pub const Slots = SlotsDirType;

        pub const Error = ErrorSet;

        pub const PageViewType = HeaderPageView;

        pub const LeafSubheader = LeafSubheaderType;
        pub const InodeSubheader = InodeSubheaderType;

        pub const LeafSubheaderView = LeafSubheaderViewType;
        pub const InodeSubheaderView = InodeSubheaderViewType;

        pub const InodeSlot = InodeSlotType;
        pub const LeafSlotHeader = LeafSlotHeaderType;

        pub const SlotsAvailableStatus = ConstSlotsDirType.AvailableStatus;
    };
}
