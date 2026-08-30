const std = @import("std");
const build_options = @import("build_options");
const PackedInt = @import("../../../core/packed_int.zig").PackedInt;
const header = @import("../../../page/header.zig");
const slots = @import("../../../slots/variadic.zig");
const errors = @import("../../../core/errors.zig");
const bpt_page = @import("../../../page/bpt.zig");
const algorithm = @import("../../../core/algorithm.zig");

pub fn View(comptime PageIdT: type, comptime IndexT: type, comptime Endian: std.builtin.Endian, comptime read_only: bool) type {
    const BptPage = bpt_page.Bpt(PageIdT, IndexT, Endian);

    //const PageIdType = PackedInt(PageIdT, Endian);

    const HeaderPageView = header.View(PageIdT, IndexT, Endian, read_only);
    const SlotsDirType = slots.Variadic(IndexT, Endian, read_only);
    const ConstSlotsDirType = slots.Variadic(IndexT, Endian, true);

    const AvailableStatus = ConstSlotsDirType.AvailableStatus;

    const ErrorSet = HeaderPageView.Error ||
        errors.BptError ||
        errors.OrderError ||
        errors.PageError ||
        errors.SlotsError;

    const LeafSubheaderType = BptPage.LeafSubheader;
    const LeafSlotHeaderType = BptPage.LeafSlotHeader;

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

    const LeafSubheaderViewType = struct {
        const Self = @This();
        const DataType = if (read_only) []const u8 else []u8;
        const PageViewType = HeaderPageView;

        const SubheaderType = LeafSubheaderType;
        const SlotHeaderType = LeafSlotHeaderType;

        const KeyType = []const u8;
        const ValueType = []const u8;

        pub const KeyValue = struct {
            key: []const u8,
            value: []const u8,
        };

        page_view: PageViewType,

        pub fn init(data: DataType) Self {
            return .{
                .page_view = PageViewType.init(data),
            };
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

        fn keyValueFromBuffer(buffer: []const u8) ErrorSet!KeyValue {
            if (buffer.len < @sizeOf(SlotHeaderType)) {
                return ErrorSet.BadData;
            }
            const slot: *const SlotHeaderType = @ptrCast(&buffer[0]);
            const key_size = @as(usize, slot.key_size.get());
            const key_offset = @sizeOf(SlotHeaderType);
            if (key_size > buffer.len - key_offset) {
                return ErrorSet.BadData;
            }
            const value_offset = key_offset + key_size;

            return .{
                .key = buffer[key_offset .. key_offset + key_size],
                .value = buffer[value_offset..],
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

        pub fn slotsDirMut(self: *Self) ErrorSet!SlotsDirType {
            const data = self.page_view.dataMut();
            return try SlotsDirType.init(data);
        }

        pub fn slotsDir(self: *const Self) ErrorSet!ConstSlotsDirType {
            const data = self.page_view.data();
            return try ConstSlotsDirType.init(data);
        }

        pub fn validatePage(
            self: *const Self,
            page_id: PageIdT,
            kind: u16,
            maximum_key_size: usize,
            maximum_value_size: usize,
        ) ErrorSet!void {
            try validatePageHeader(&self.page_view, page_id, kind, @sizeOf(SubheaderType));

            const slot_dir = try self.slotsDir();
            try slot_dir.validateStructural();
            const count = slot_dir.size();
            var index: usize = 0;
            while (index < count) : (index += 1) {
                const entry = try keyValueFromBuffer(try slot_dir.get(index));
                if (entry.key.len > maximum_key_size or entry.value.len > maximum_value_size) {
                    return ErrorSet.BadData;
                }
            }

            if (build_options.full_validation) {
                try slot_dir.validate();
            }
        }

        pub fn insert(self: *Self, index: usize, key: []const u8, value: []const u8) ErrorSet!void {
            const total_size: usize = @sizeOf(SlotHeaderType) + key.len + value.len;
            var slot_dir = try self.slotsDirMut();
            var buffer = try slot_dir.reserveGetAt(index, total_size);
            var slot: *SlotHeaderType = @ptrCast(&buffer[0]);

            slot.key_size.set(@as(@TypeOf(slot.key_size.get()), @intCast(key.len)));

            const key_dst = buffer[@sizeOf(SlotHeaderType)..][0..key.len];
            @memcpy(key_dst, key);

            const value_dst = buffer[@sizeOf(SlotHeaderType) + key.len ..][0..value.len];
            @memcpy(value_dst, value);
        }

        pub fn capacityFor(self: *const Self, data_len: usize) ErrorSet!usize {
            const maximum_slot_size = data_len + @sizeOf(SlotHeaderType);
            return (try self.slotsDir()).capacityFor(maximum_slot_size);
        }

        pub fn canUpdate(self: *const Self, pos: usize, key: []const u8, value: []const u8) ErrorSet!AvailableStatus {
            const total_size: usize = @sizeOf(SlotHeaderType) + key.len + value.len;
            var slot_dir = try self.slotsDir();
            return try slot_dir.canUpdate(pos, total_size);
        }

        pub fn lowerBoundWith(
            self: *const Self,
            key: []const u8,
            comptime cmp: anytype, // comparator function fn (ctx, a, b) std.math.Order
            ctx: anytype, // context for comparator
        ) ErrorSet!usize {
            const Ctx = @TypeOf(ctx);
            const Wrapper = struct {
                slot_dir: ConstSlotsDirType,
                user_ctx: Ctx,

                fn less(wrapper: *const @This(), a: ConstSlotsDirType.Entry, key_b: []const u8) !std.math.Order {
                    const slot_key = try wrapper.slot_dir.getByEntry(&a);
                    const slot_values = try keyValueFromBuffer(slot_key);
                    return cmp(wrapper.user_ctx, slot_values.key, key_b);
                }
            };

            const slot_dir = try self.slotsDir();
            const wrapper = Wrapper{ .slot_dir = slot_dir, .user_ctx = ctx };
            return try algorithm.lowerBound(ConstSlotsDirType.Entry, slot_dir.entries(), key, Wrapper.less, &wrapper);
        }

        pub fn canInsert(self: *const Self, pos: usize, key: []const u8, value: []const u8) ErrorSet!AvailableStatus {
            _ = pos;
            const total_len = key.len + value.len + @sizeOf(SlotHeaderType);
            return (try self.slotsDir()).canInsert(total_len);
        }

        pub fn canUpdateValue(self: *const Self, pos: usize, value: []const u8) ErrorSet!AvailableStatus {
            const key = (try self.get(pos)).key;
            const slot_dir = try self.slotsDir();
            const status = try slot_dir.canUpdate(pos, @sizeOf(SlotHeaderType) + key.len + value.len);
            return status;
        }

        pub fn updateValue(self: *Self, pos: usize, value: []const u8, tmp_buf: []u8) ErrorSet!void {
            const old_value = try self.get(pos);
            const new_total_size = @sizeOf(SlotHeaderType) + old_value.key.len + value.len;

            if (tmp_buf.len < new_total_size) {
                return ErrorSet.BufferTooSmall;
            }

            var new_buffer = tmp_buf[0..new_total_size];

            var slot: *SlotHeaderType = @ptrCast(&new_buffer[0]);
            slot.key_size.set(@as(@TypeOf(slot.key_size.get()), @intCast(old_value.key.len)));

            const key_dst = new_buffer[@sizeOf(SlotHeaderType)..][0..old_value.key.len];
            @memcpy(key_dst, old_value.key);

            const value_dst = new_buffer[@sizeOf(SlotHeaderType) + old_value.key.len ..][0..value.len];
            @memcpy(value_dst, value);

            const tail_buf = tmp_buf[new_total_size..];

            const update_status = try self.canUpdateValue(pos, value);
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

        pub fn get(self: *const Self, pos: usize) ErrorSet!KeyValue {
            const slot_dir = try self.slotsDir();
            const slot_buffer = try slot_dir.get(pos);
            return try keyValueFromBuffer(slot_buffer);
        }
    };

    const InodeSubheaderType = BptPage.InodeSubheader;
    const InodeSlotHeaderType = BptPage.InodeSlotHeader;

    const InodeSubheaderViewType = struct {
        const Self = @This();
        const DataType = if (read_only) []const u8 else []u8;
        const PageViewType = HeaderPageView;

        const SubheaderType = InodeSubheaderType;
        const SlotHeaderType = InodeSlotHeaderType;
        const KeyType = []const u8;

        const KeyChild = struct {
            key: []const u8,
            child: PageIdT,
        };

        page_view: PageViewType,

        pub fn init(data: DataType) Self {
            return .{
                .page_view = PageViewType.init(data),
            };
        }

        pub fn page(self: *const Self) DataType {
            return self.page_view.page;
        }

        pub fn totalSlotSize(_: *const Self, key_len: usize) usize {
            return key_len + @sizeOf(SlotHeaderType);
        }

        fn keyChildFromBuffer(buffer: []const u8) ErrorSet!KeyChild {
            if (buffer.len < @sizeOf(SlotHeaderType)) {
                return ErrorSet.BadData;
            }
            const slot: *const SlotHeaderType = @ptrCast(&buffer[0]);
            if (slot.child.isMax()) {
                return ErrorSet.BadData;
            }
            const key_offset = @sizeOf(SlotHeaderType);
            const key_size = @as(usize, buffer.len - key_offset);
            return .{
                .key = buffer[key_offset .. key_offset + key_size],
                .child = slot.child.get(),
            };
        }

        pub fn formatPage(self: *Self, kind: u16, page_id: PageIdT, metadata_len: IndexT) ErrorSet!void {
            self.page_view.formatPage(kind, page_id, @as(IndexT, @intCast(@sizeOf(SubheaderType))), metadata_len);

            const data = self.page_view.dataMut();
            var sl = try SlotsDirType.init(data);
            sl.formatHeader();

            var sh = self.subheaderMut();
            sh.parent.setMax();
            sh.rightmost_child.setMax();
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
            const data = self.page_view.dataMut();
            return try SlotsDirType.init(data);
        }

        pub fn slotsDir(self: *const Self) ErrorSet!ConstSlotsDirType {
            const data = self.page_view.data();
            return try ConstSlotsDirType.init(data);
        }

        pub fn validatePage(
            self: *const Self,
            page_id: PageIdT,
            kind: u16,
            maximum_key_size: usize,
        ) ErrorSet!void {
            try validatePageHeader(&self.page_view, page_id, kind, @sizeOf(SubheaderType));

            const slot_dir = try self.slotsDir();
            try slot_dir.validateStructural();
            const count = slot_dir.size();
            if (count > 0 and self.subheader().rightmost_child.isMax()) {
                return ErrorSet.BadData;
            }
            var index: usize = 0;
            while (index < count) : (index += 1) {
                const entry = try keyChildFromBuffer(try slot_dir.get(index));
                if (entry.key.len > maximum_key_size) {
                    return ErrorSet.BadData;
                }
            }

            if (build_options.full_validation) {
                try slot_dir.validate();
            }
        }

        pub fn insert(self: *Self, index: usize, key: []const u8, child: PageIdT) ErrorSet!void {
            if (child == std.math.maxInt(PageIdT)) {
                return ErrorSet.BadData;
            }
            const total_size: usize = @sizeOf(SlotHeaderType) + key.len;
            var slot_dir = try self.slotsDirMut();
            var buffer = try slot_dir.reserveGetAt(index, total_size);
            var slot: *SlotHeaderType = @ptrCast(&buffer[0]);
            slot.child.set(child);
            const key_dst = buffer[@sizeOf(SlotHeaderType)..][0..key.len];
            @memcpy(key_dst, key);
        }

        pub fn capacityFor(self: *const Self, data_len: usize) ErrorSet!usize {
            const maximum_slot_size = data_len + @sizeOf(SlotHeaderType);
            return (try self.slotsDir()).capacityFor(maximum_slot_size);
        }

        pub fn canInsert(self: *const Self, _: usize, key: []const u8, _: PageIdT) ErrorSet!AvailableStatus {
            const total_size: usize = @sizeOf(SlotHeaderType) + key.len;
            var slot_dir = try self.slotsDir();
            return try slot_dir.canInsert(total_size);
        }

        pub fn canUpdate(self: *const Self, pos: usize, key: []const u8) ErrorSet!AvailableStatus {
            const total_size: usize = @sizeOf(SlotHeaderType) + key.len;
            var slot_dir = try self.slotsDir();
            return try slot_dir.canUpdate(pos, total_size);
        }

        pub fn updateChild(self: *Self, pos: usize, child: PageIdT) ErrorSet!void {
            if (child == std.math.maxInt(PageIdT)) {
                return ErrorSet.BadData;
            }
            var slot_dir = try self.slotsDirMut();
            const buffer = try slot_dir.getMut(pos);
            if (buffer.len < @sizeOf(SlotHeaderType)) {
                return ErrorSet.BadData;
            }
            var slot: *SlotHeaderType = @ptrCast(&buffer[0]);
            slot.child.set(child);
        }

        pub fn updateKey(self: *Self, pos: usize, key: []const u8, tmp_buf: []u8) ErrorSet!void {
            const old_value = try self.get(pos);
            const new_total_size = @sizeOf(SlotHeaderType) + key.len;
            if (tmp_buf.len < new_total_size) {
                return ErrorSet.BufferTooSmall;
            }
            var new_buffer = tmp_buf[0..new_total_size];

            var slot: *SlotHeaderType = @ptrCast(&new_buffer[0]);
            slot.child.set(old_value.child);

            const key_dst = new_buffer[@sizeOf(SlotHeaderType)..][0..key.len];
            @memcpy(key_dst, key);

            const tail_buf = tmp_buf[new_total_size..];

            const update_status = try self.canUpdate(pos, key);
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

        pub fn upperBoundWith(
            self: *const Self,
            key: []const u8,
            comptime cmp: anytype, // comparator function fn (ctx, a, b) std.math.Order
            ctx: anytype, // context for comparator
        ) ErrorSet!usize {
            const Ctx = @TypeOf(ctx);
            const Wrapper = struct {
                slot_dir: ConstSlotsDirType,
                user_ctx: Ctx,

                fn less(wrapper: *const @This(), a: ConstSlotsDirType.Entry, key_b: []const u8) !std.math.Order {
                    const slot_key = try wrapper.slot_dir.getByEntry(&a);
                    const slot_values = try keyChildFromBuffer(slot_key);
                    return cmp(wrapper.user_ctx, slot_values.key, key_b);
                }
            };

            const slot_dir = try self.slotsDir();
            const wrapper = Wrapper{ .slot_dir = slot_dir, .user_ctx = ctx };
            return try algorithm.upperBound(ConstSlotsDirType.Entry, slot_dir.entries(), key, Wrapper.less, &wrapper);
        }

        pub fn get(self: *const Self, pos: usize) ErrorSet!KeyChild {
            const slot_dir = try self.slotsDir();
            const slot_buffer = try slot_dir.get(pos);
            return try keyChildFromBuffer(slot_buffer);
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

        pub const InodeSlotHeader = InodeSlotHeaderType;
        pub const LeafSlotHeader = LeafSlotHeaderType;

        pub const SlotsAvailableStatus = ConstSlotsDirType.AvailableStatus;
        pub const full_validation_enabled = build_options.full_validation;
    };
}
