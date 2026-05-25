const std = @import("std");
const header = @import("../../../page/header.zig");
const slots = @import("../../../slots/variadic.zig");
const errors = @import("../../../core/errors.zig");

const SkipListPage = @import("../../../page/skip_list.zig").SkipList;

pub fn View(comptime PageIdT: type, comptime IndexT: type, comptime Endian: std.builtin.Endian, comptime read_only: bool) type {
    const HeaderPageView = header.View(PageIdT, IndexT, Endian, read_only);
    const SlotsDirType = slots.Variadic(IndexT, Endian, read_only);
    const ConstSlotsDirType = slots.Variadic(IndexT, Endian, true);

    return struct {
        const Self = @This();

        const DataType = if (read_only) []const u8 else []u8;
        const PageViewType = HeaderPageView;
        const ErrorSet = SlotsDirType.Error;

        const SubheaderType = SkipListPage(PageIdT, IndexT, Endian).SkipListSubheader;
        const SlotHeaderType = SkipListPage(PageIdT, IndexT, Endian).SkipListNodeType;

        const KeyType = []const u8;
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

        pub fn page(self: *const Self) DataType {
            return self.page_view.page;
        }

        pub fn totalSlotSize(_: *const Self, key_len: usize, value_len: usize) usize {
            return key_len + value_len + @sizeOf(SlotHeaderType);
        }

        pub fn entries(self: *const Self) !usize {
            return (try self.slotsDir()).size();
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

        pub fn slotsDirMut(self: *Self) ErrorSet!SlotsDirType {
            if (read_only) {
                @compileError("Cannot get mutable slots directory from a read-only page");
            }
            const data = self.page_view.dataMut();
            return try SlotsDirType.init(data);
        }

        pub fn slotsDir(self: *const Self) ErrorSet!ConstSlotsDirType {
            const data = self.page_view.data();
            return try ConstSlotsDirType.init(data);
        }
    };
}
