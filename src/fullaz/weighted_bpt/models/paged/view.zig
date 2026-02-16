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

    const WeightValue = struct {
        weight: Weight,
        value: []const u8,
    };

    const ChildWeightValue = struct {
        child: PageIdT,
        weight: Weight,
    };

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

        // parent, prev, next
        pub fn getParent(self: *const Self) ErrorSet!?PageIdT {
            const val = self.subheader().parent.get();
            if (self.subheader().parent.isMax()) {
                return null;
            }
            return val;
        }
        pub fn getPrev(self: *const Self) ErrorSet!?PageIdT {
            const val = self.subheader().prev.get();
            if (self.subheader().prev.isMax()) {
                return null;
            }
            return val;
        }
        pub fn getNext(self: *const Self) ErrorSet!?PageIdT {
            const val = self.subheader().next.get();
            if (self.subheader().next.isMax()) {
                return null;
            }
            return val;
        }

        pub fn setParent(self: *Self, parent: ?PageIdT) ErrorSet!void {
            if (parent) |val| {
                self.subheaderMut().parent.set(val);
            } else {
                self.subheaderMut().parent.setMax();
            }
        }

        pub fn setPrev(self: *Self, prev: ?PageIdT) ErrorSet!void {
            if (prev) |val| {
                self.subheaderMut().prev.set(val);
            } else {
                self.subheaderMut().prev.setMax();
            }
        }

        pub fn setNext(self: *Self, next: ?PageIdT) ErrorSet!void {
            if (next) |val| {
                self.subheaderMut().next.set(val);
            } else {
                self.subheaderMut().next.setMax();
            }
        }

        pub fn capacityFor(self: *const Self, data_len: usize) ErrorSet!usize {
            const maximum_slot_size = data_len + @sizeOf(SlotHeaderType);
            return (try self.slotsDir()).capacityFor(maximum_slot_size);
        }

        pub fn canInsert(self: *const Self, value: []const u8) ErrorSet!AvailableStatus {
            return self.canInsertSize(@sizeOf(SlotHeaderType) + value.len);
        }

        pub fn canInsertSize(self: *const Self, value_len: usize) ErrorSet!AvailableStatus {
            return (try self.slotsDir()).canInsert(value_len);
        }

        pub fn canInsert2(self: *const Self, a: usize, b: usize) ErrorSet!AvailableStatus {
            const header_size = @sizeOf(SlotHeaderType);
            return (try self.slotsDir()).canInsert2(a + header_size, b + header_size);
        }

        pub fn canInsert3(self: *const Self, a: usize, b: usize, c: usize) ErrorSet!AvailableStatus {
            const header_size = @sizeOf(SlotHeaderType);
            return (try self.slotsDir()).canInsert3(a + header_size, b + header_size, c + header_size);
        }

        pub fn insert(self: *Self, index: usize, weight: Weight, value: []const u8) ErrorSet!void {
            const hdr_size = @sizeOf(SlotHeaderType);
            const total_size: usize = hdr_size + value.len;
            var slot_dir = try self.slotsDirMut();
            var buffer = try slot_dir.reserveGet(index, total_size);
            var slot: *SlotHeaderType = @ptrCast(&buffer[0]);
            slot.weight.set(weight);

            const value_dst = buffer[hdr_size..][0..value.len];
            @memcpy(value_dst, value);
        }

        pub fn get(self: *const Self, pos: usize) ErrorSet!WeightValue {
            const slots_dir = try self.slotsDir();
            const buffer = try slots_dir.get(pos);
            const slot: *const SlotHeaderType = @ptrCast(&buffer[0]);
            return .{
                .weight = slot.weight.get(),
                .value = buffer[@sizeOf(SlotHeaderType)..],
            };
        }

        pub fn canUpdate(self: *const Self, pos: usize, value: []const u8) ErrorSet!AvailableStatus {
            const total_size: usize = @sizeOf(SlotHeaderType) + value.len;
            var slot_dir = try self.slotsDir();
            return try slot_dir.canUpdate(pos, total_size);
        }

        pub fn update(self: *Self, pos: usize, weight: Weight, value: []const u8, tmp_buf: []u8) ErrorSet!void {
            const new_total_size = @sizeOf(SlotHeaderType) + value.len;

            if (tmp_buf.len < new_total_size) {
                return ErrorSet.BufferTooSmall;
            }

            var new_buffer = tmp_buf[0..new_total_size];

            var slot: *SlotHeaderType = @ptrCast(&new_buffer[0]);
            slot.weight.set(weight);

            const value_dst = new_buffer[@sizeOf(SlotHeaderType)..][0..value.len];
            @memcpy(value_dst, value);

            const tail_buf = tmp_buf[new_total_size..];

            const update_status = try self.canUpdate(pos, value);
            if (update_status == .not_enough) {
                return ErrorSet.NotEnoughSpace;
            } else if (update_status == .need_compact) {
                var slot_dir = try self.slotsDirMut();
                try slot_dir.free(pos);
                slot_dir.compactWithBuffer(tail_buf) catch {
                    try slot_dir.compactInPlace();
                };
            }
            var slot_dir = try self.slotsDirMut();
            const buffer = try slot_dir.resizeGet(pos, new_total_size);
            @memcpy(buffer, new_buffer);
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

        pub fn capacityFor(self: *const Self) ErrorSet!usize {
            const maximum_slot_size = @sizeOf(SlotHeaderType);
            return (try self.slotsDir()).capacityFor(maximum_slot_size);
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

        pub fn getParent(self: *const Self) ErrorSet!?PageIdT {
            const val = self.subheader().parent.get();
            if (self.subheader().parent.isMax()) {
                return null;
            }
            return val;
        }

        pub fn setParent(self: *Self, parent: ?PageIdT) ErrorSet!void {
            if (parent) |val| {
                self.subheaderMut().parent.set(val);
            } else {
                self.subheaderMut().parent.setMax();
            }
        }

        pub fn insert(self: *Self, index: usize, child_page_id: PageIdT, weight: Weight) ErrorSet!void {
            const slot_size = @sizeOf(SlotHeaderType);
            var slot_dir = try self.slotsDirMut();
            var buffer = try slot_dir.reserveGet(index, slot_size);
            var slot: *SlotHeaderType = @ptrCast(&buffer[0]);
            slot.child.set(child_page_id);
            slot.weight.set(weight);
            var hdr = self.subheaderMut();
            const old_total = hdr.total_weight.get();
            hdr.total_weight.set(old_total + weight);
        }

        pub fn get(self: *const Self, pos: usize) ErrorSet!ChildWeightValue {
            const slots_dir = try self.slotsDir();
            const buffer = try slots_dir.get(pos);
            const slot: *const SlotHeaderType = @ptrCast(&buffer[0]);
            return .{
                .child = slot.child.get(),
                .weight = slot.weight.get(),
            };
        }

        pub fn updateWeight(self: *Self, pos: usize, new_weight: Weight) ErrorSet!void {
            var slot_dir = try self.slotsDirMut();
            const buffer = try slot_dir.getMut(pos);
            var slot: *SlotHeaderType = @ptrCast(&buffer[0]);
            const old_weight = slot.weight.get();
            slot.weight.set(new_weight);

            var hdr = self.subheaderMut();
            const total_weight = hdr.total_weight.get();
            hdr.total_weight.set(total_weight - old_weight + new_weight);
        }

        pub fn updateChild(self: *Self, pos: usize, new_child: PageIdT) ErrorSet!void {
            var slot_dir = try self.slotsDirMut();
            const buffer = try slot_dir.getMut(pos);
            var slot: *SlotHeaderType = @ptrCast(&buffer[0]);
            slot.child.set(new_child);
        }

        pub fn canInsert(self: *const Self, _: usize, _: Weight) ErrorSet!AvailableStatus {
            const slot_size = @sizeOf(SlotHeaderType);
            const slot_dir = try self.slotsDir();
            return try slot_dir.canInsert(slot_size);
        }
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
