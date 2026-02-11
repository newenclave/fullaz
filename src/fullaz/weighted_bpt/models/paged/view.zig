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

    //const AvailableStatus = ConstSlotsDirType.AvailableStatus;

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
    };

    const InodeSubheaderType = WBptPage.InodeSubheader;
    const InodeSlotType = WBptPage.InodeSlot;
    const InodeSubheaderViewType = struct {
        const Self = @This();
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
