const std = @import("std");
const page = @import("../../../../page/fsm.zig");
const header = @import("../../../../page/header.zig");
const slots = @import("../../../../slots/fixed.zig");
const errors = @import("../../../../core/errors.zig");

const SlotInfoImpl = @import("../../slot_info.zig").SlotInfo;

pub fn View(comptime PageIdT: type, comptime IndexT: type, comptime SizeClassT: type, comptime Endian: std.builtin.Endian, comptime read_only: bool) type {
    const HeaderPageViewT = header.View(PageIdT, IndexT, Endian, read_only);
    const SlotsDirType = slots.Fixed(u16, IndexT, Endian, read_only);
    const ConstSlotsDirType = slots.Fixed(u16, IndexT, Endian, true);

    const Fsm = page.Fsm(PageIdT, IndexT, SizeClassT, Endian);
    const Slot = Fsm.Slot;

    const ErrorSet = ConstSlotsDirType.Error ||
        errors.OrderError ||
        errors.PageError ||
        errors.SlotsError;

    const SlabPageViewImpl = struct {
        const Self = @This();
        const DataType = if (read_only) []const u8 else []u8;

        pub const PageHeader = Fsm.PageHeader;
        pub const PageView = HeaderPageViewT;
        pub const SubHeader = Fsm.Subheader;
        pub const Error = ErrorSet;
        pub const Pid = PageIdT;
        pub const SizeClass = SizeClassT;
        pub const Index = IndexT;
        pub const SubheaderType = Fsm.Subheader;
        pub const SlotInfo = SlotInfoImpl(PageIdT, IndexT);

        const PageViewType = PageView;
        const SlotHeaderType = Fsm.Subheader;

        page_view: PageViewType,

        pub fn init(data: DataType) Self {
            return .{
                .page_view = PageViewType.init(data),
            };
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn page(self: *const Self) DataType {
            return self.page_view.page;
        }

        pub fn pageHeaderMut(self: *Self) *PageViewType.PageHeader {
            if (read_only) {
                @compileError("Cannot get mutable page from a read-only view");
            }
            return self.page_view.headerMut();
        }

        pub fn pageHeader(self: *const Self) *const PageViewType.PageHeader {
            return self.page_view.header();
        }

        pub fn formatPage(self: *Self, kind: u16, page_id: PageIdT, metadata_len: IndexT, size_class: SizeClassT) ErrorSet!void {
            const subheader_size = @as(IndexT, @intCast(@sizeOf(SubheaderType)));
            self.page_view.formatPage(kind, page_id, subheader_size, metadata_len);
            const data = self.page_view.dataMut();

            var sh = self.subheaderMut();
            sh.formatHeader();
            sh.size_class.set(size_class);

            var sl = try SlotsDirType.init(data);
            try sl.format(@sizeOf(Slot));
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

        pub fn slotsDir(self: *const Self) ErrorSet!ConstSlotsDirType {
            const data = self.page_view.data();
            return try ConstSlotsDirType.init(data);
        }

        pub fn slotsDirMut(self: *Self) ErrorSet!SlotsDirType {
            if (read_only) {
                @compileError("Cannot get mutable slots directory from a read-only page");
            }
            const data = self.page_view.dataMut();
            return try SlotsDirType.init(data);
        }

        pub fn insert(self: *Self, pid: Pid, size: Index) Error!SlotInfo {
            var slots_dir = try self.slotsDirMut();
            const all = try slots_dir.capacity();
            const used = try slots_dir.size();
            if (all == used) {
                return Error.OutOfBounds;
            }

            const first_free = try slots_dir.getFirstFree();
            if (first_free) |slot_index| {
                try slots_dir.markUsed(slot_index);
                errdefer slots_dir.clear(slot_index) catch {};
                var slot_data: *Slot = @ptrCast((try slots_dir.getMut(slot_index)).ptr);
                slot_data.pid.set(pid);
                slot_data.free_space.set(size);
                return .{
                    .pid = undefined, // will be set below
                    .free_space = size,
                    .slot_id = slot_index,
                };
            }
            return Error.OutOfBounds;
        }

        pub fn remove(self: *Self, slot: usize) ErrorSet!void {
            var slots_dir = try self.slotsDirMut();
            if (slot >= try slots_dir.capacity()) {
                return Error.OutOfBounds;
            }
            try slots_dir.clear(slot);
        }

        pub fn setNext(self: *Self, next_page_id: ?PageIdT) ErrorSet!void {
            if (read_only) {
                @compileError("Cannot set next page on a read-only page");
            }
            var sh = self.subheaderMut();
            if (next_page_id) |id| {
                sh.next.set(id);
            } else {
                sh.next.setMax();
            }
        }

        pub fn setPrev(self: *Self, prev_page_id: ?PageIdT) ErrorSet!void {
            if (read_only) {
                @compileError("Cannot set previous page on a read-only page");
            }
            var sh = self.subheaderMut();
            if (prev_page_id) |id| {
                sh.prev.set(id);
            } else {
                sh.prev.setMax();
            }
        }

        pub fn getNext(self: *const Self) ?PageIdT {
            const sh = self.subheader();
            const next_id = sh.next.get();
            if (sh.next.isMax()) {
                return null;
            }
            return next_id;
        }

        pub fn getPrev(self: *const Self) ?PageIdT {
            const sh = self.subheader();
            const prev_id = sh.prev.get();
            if (sh.prev.isMax()) {
                return null;
            }
            return prev_id;
        }

        pub fn sizeClass(self: *const Self) SizeClassT {
            const sh = self.subheader();
            return sh.size_class.get();
        }

        pub fn isFull(self: *const Self) Error!bool {
            const slots_dir = try self.slotsDir();
            return slots_dir.isFull();
        }

        pub fn isEmpty(self: *const Self) Error!bool {
            return try self.usedSlots() == 0;
        }

        pub fn usedSlots(self: *const Self) Error!usize {
            const slots_dir = try self.slotsDir();
            return slots_dir.size();
        }

        pub fn capacity(self: *const Self) Error!usize {
            const slots_dir = try self.slotsDir();
            return slots_dir.capacity();
        }

        pub fn findBySize(self: *const Self, needed_size: IndexT) Error!?SlotInfo {
            const slots_dir = try self.slotsDir();
            const all = try slots_dir.capacity();
            for (0..all) |i| {
                if (!try slots_dir.isSet(i)) {
                    continue;
                }
                const slot = try slots_dir.get(i);
                const slot_data: *const Slot = @ptrCast(slot.ptr);
                if (slot_data.free_space.get() >= needed_size) {
                    return .{
                        .pid = slot_data.pid.get(),
                        .free_space = slot_data.free_space.get(),
                        .slot_id = i,
                    };
                }
            }
            return null;
        }

        pub fn findByPid(self: *const Self, pid: Pid) Error!?SlotInfo {
            const slots_dir = try self.slotsDir();
            const all = try slots_dir.capacity();
            for (0..all) |i| {
                if (!try slots_dir.isSet(i)) {
                    continue;
                }
                const slot = try slots_dir.get(i);
                const slot_data: *const Slot = @ptrCast(slot.ptr);
                if (slot_data.pid.get() == pid) {
                    return .{
                        .pid = undefined, // will be set below
                        .free_space = slot_data.free_space.get(),
                        .slot_id = i,
                    };
                }
            }
            return null;
        }
    };

    return struct {
        pub const Error = ErrorSet;
        pub const SlabPageView = SlabPageViewImpl;
        pub const HeaderPageView = HeaderPageViewT;
    };
}
