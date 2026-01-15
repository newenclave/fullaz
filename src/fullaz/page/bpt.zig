const std = @import("std");
const header = @import("header.zig");
const SubheaderView = @import("subheader.zig").View;
const PackedInt = @import("../packed_int.zig").PackedInt;
const slots = @import("../slots/slots.zig");
const algorithm = @import("../algorithm.zig");

pub fn Bpt(comptime PageIdT: type, comptime IndexT: type, comptime Endian: std.builtin.Endian, comptime read_only: bool) type {
    const PageIdType = PackedInt(PageIdT, Endian);
    const IndexType = PackedInt(IndexT, Endian);

    const HeaderPageView = header.View(PageIdT, IndexT, Endian, read_only);
    const SlotsDirType = slots.Variadic(IndexT, Endian, read_only);
    const ConstSlotsDirType = slots.Variadic(IndexT, Endian, true);

    const AvailableStatus = ConstSlotsDirType.AvailableStatus;

    const LeafSubheaderType = extern struct {
        const Self = @This();
        parent: PageIdType,
        prev: PageIdType,
        next: PageIdType,
        pub fn formatHeader(self: *Self) void {
            self.parent.set(@TypeOf(self.parent).max());
            self.prev.set(@TypeOf(self.prev).max());
            self.next.set(@TypeOf(self.next).max());
        }
    };

    const LeafSlotHeaderType = extern struct {
        key_size: IndexType,
    };

    const LeafSubheaderViewType = struct {
        const Self = @This();
        const DataType = if (read_only) []const u8 else []u8;
        const PageViewType = HeaderPageView;

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

        pub fn entries(self: *const Self) !usize {
            return (try self.slotsDir()).size();
        }

        fn keyValueFromBuffer(buffer: []const u8) !KeyValue {
            const slot: *const LeafSlotHeaderType = @ptrCast(&buffer[0]);
            const key_size = @as(usize, slot.key_size.get());
            const key_offset = @sizeOf(LeafSlotHeaderType);
            const value_offset = key_offset + key_size;

            return .{
                .key = buffer[key_offset .. key_offset + key_size],
                .value = buffer[value_offset..],
            };
        }

        pub fn formatPage(self: *Self, kind: u16, page_id: PageIdT, metadata_len: IndexT) !void {
            self.page_view.formatPage(kind, page_id, @as(IndexT, @intCast(@sizeOf(LeafSubheaderType))), metadata_len);
            const data = self.page_view.dataMut();
            var sl = try SlotsDirType.init(data);
            self.subheaderMut().formatHeader();
            sl.formatHeader();
        }

        pub fn subheader(self: *const Self) *const LeafSubheaderType {
            const subhdr = self.page_view.subheader();
            return @ptrCast(@alignCast(&subhdr[0]));
        }

        pub fn subheaderMut(self: *Self) *LeafSubheaderType {
            if (read_only) {
                @compileError("Cannot get mutable subheader from a read-only page");
            }
            const subhdr = self.page_view.subheaderMut();
            return @ptrCast(@alignCast(&subhdr[0]));
        }

        pub fn slotsDirMut(self: *Self) !SlotsDirType {
            const data = self.page_view.dataMut();
            return try SlotsDirType.init(data);
        }

        pub fn slotsDir(self: *const Self) !ConstSlotsDirType {
            const data = self.page_view.data();
            return try ConstSlotsDirType.init(data);
        }

        pub fn insert(self: *Self, index: usize, key: []const u8, value: []const u8) !void {
            const total_size: usize = @sizeOf(LeafSlotHeaderType) + key.len + value.len;
            var slot_dir = try self.slotsDirMut();
            var buffer = try slot_dir.reserveGet(index, total_size);
            var slot: *LeafSlotHeaderType = @ptrCast(&buffer[0]);

            slot.key_size.set(@as(@TypeOf(slot.key_size.get()), @intCast(key.len)));

            const key_dst = buffer[@sizeOf(LeafSlotHeaderType)..][0..key.len];
            @memcpy(key_dst, key);

            const value_dst = buffer[@sizeOf(LeafSlotHeaderType) + key.len ..][0..value.len];
            @memcpy(value_dst, value);
        }

        pub fn canInsert(self: *const Self, _: usize, key: []const u8, value: []const u8) !AvailableStatus {
            const total_size: usize = @sizeOf(LeafSlotHeaderType) + key.len + value.len;
            var slot_dir = try self.slotsDir();
            return try slot_dir.canInsert(total_size);
        }

        pub fn canUpdate(self: *const Self, pos: usize, key: []const u8, value: []const u8) !AvailableStatus {
            const total_size: usize = @sizeOf(LeafSlotHeaderType) + key.len + value.len;
            var slot_dir = try self.slotsDir();
            return try slot_dir.canUpdate(pos, total_size);
        }

        pub fn lowerBoundWith(
            self: *const Self,
            key: []const u8,
            comptime cmp: anytype, // comparator function fn (ctx, a, b) algorithm.Order
            ctx: anytype, // context for comparator
        ) !usize {
            const Ctx = @TypeOf(ctx);
            const Wrapper = struct {
                slot_dir: ConstSlotsDirType,
                user_ctx: Ctx,

                fn less(wrapper: *const @This(), a: ConstSlotsDirType.Entry, key_b: []const u8) !algorithm.Order {
                    const slot_key = try wrapper.slot_dir.getByEntry(&a);
                    const slot_values = try keyValueFromBuffer(slot_key);
                    return cmp(wrapper.user_ctx, slot_values.key, key_b);
                }
            };

            const slot_dir = try self.slotsDir();
            const wrapper = Wrapper{ .slot_dir = slot_dir, .user_ctx = ctx };
            return try algorithm.lowerBound(ConstSlotsDirType.Entry, slot_dir.entriesConst(), key, Wrapper.less, &wrapper);
        }

        pub fn canUpdateValue(self: *const Self, pos: usize, key: []const u8, value: []const u8) !AvailableStatus {
            const slot_dir = try self.slotsDir();
            const status = try slot_dir.canUpdate(pos, @sizeOf(LeafSlotHeaderType) + key.len + value.len);
            return status;
        }

        pub fn updateValue(self: *Self, pos: usize, value: []const u8, tmp_buf: []u8) !void {
            const old_value = try self.get(pos);
            const new_total_size = @sizeOf(LeafSlotHeaderType) + old_value.key.len + value.len;
            var new_buffer = tmp_buf[0..new_total_size];
            var slot: *LeafSlotHeaderType = @ptrCast(&new_buffer[0]);
            slot.key_size.set(@as(@TypeOf(slot.key_size.get()), @intCast(old_value.key.len)));
            const key_dst = new_buffer[@sizeOf(LeafSlotHeaderType)..][0..old_value.key.len];
            @memcpy(key_dst, old_value.key);
            const value_dst = new_buffer[@sizeOf(LeafSlotHeaderType) + old_value.key.len ..][0..value.len];
            @memcpy(value_dst, value);

            const update_status = try self.canUpdateValue(pos, old_value.key, value);
            if (update_status == .not_enough) {
                return error.NotEnoughSpaceForUpdate;
            } else if (update_status == .need_compact) {
                var slot_dir = try self.slotsDirMut();
                try slot_dir.free(pos);
                try slot_dir.compactInPlace();
            }
            var slot_dir = try self.slotsDirMut();
            const buffer = try slot_dir.resizeGet(pos, new_total_size);
            @memcpy(buffer, new_buffer);
        }

        pub fn get(self: *const Self, pos: usize) !KeyValue {
            const slot_dir = try self.slotsDir();
            const slot_buffer = try slot_dir.get(pos);
            return keyValueFromBuffer(slot_buffer);
        }
    };

    const InodeSubheaderType = extern struct {
        parent: PageIdType,
        rightmost_child: PageIdType,
    };

    const InodeSlotHeaderType = extern struct {
        child: PageIdType,
    };

    const InodeSubheaderViewType = struct {
        const Self = @This();
        const DataType = if (read_only) []const u8 else []u8;
        const PageViewType = HeaderPageView;

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

        fn keyChildFromBuffer(buffer: []const u8) !KeyChild {
            const slot: *const InodeSlotHeaderType = @ptrCast(&buffer[0]);
            const key_offset = @sizeOf(InodeSlotHeaderType);
            const key_size = @as(usize, buffer.len - key_offset);
            return .{
                .key = buffer[key_offset .. key_offset + key_size],
                .child = slot.child.get(),
            };
        }

        pub fn formatPage(self: *Self, kind: u16, page_id: PageIdT, metadata_len: IndexT) !void {
            self.page_view.formatPage(kind, page_id, @as(IndexT, @intCast(@sizeOf(InodeSubheaderType))), metadata_len);

            const data = self.page_view.dataMut();
            var sl = try SlotsDirType.init(data);
            sl.formatHeader();

            var sh = self.subheaderMut();
            sh.parent.set(PageIdType.max());
            sh.rightmost_child.set(PageIdType.max());
        }

        pub fn subheader(self: *const Self) *const InodeSubheaderType {
            const subhdr = self.page_view.subheader();
            return @ptrCast(@alignCast(&subhdr[0]));
        }

        pub fn subheaderMut(self: *Self) *InodeSubheaderType {
            if (read_only) {
                @compileError("Cannot get mutable subheader from a read-only page");
            }
            const subhdr = self.page_view.subheaderMut();
            return @ptrCast(@alignCast(&subhdr[0]));
        }

        pub fn slotsDirMut(self: *Self) !SlotsDirType {
            const data = self.page_view.dataMut();
            return try SlotsDirType.init(data);
        }

        pub fn slotsDir(self: *const Self) !ConstSlotsDirType {
            const data = self.page_view.data();
            return try ConstSlotsDirType.init(data);
        }

        pub fn insert(self: *Self, index: usize, key: []const u8, child: PageIdT) !void {
            const total_size: usize = @sizeOf(InodeSlotHeaderType) + key.len;
            var slot_dir = try self.slotsDirMut();
            var buffer = try slot_dir.reserveGet(index, total_size);
            var slot: *InodeSlotHeaderType = @ptrCast(&buffer[0]);
            slot.child.set(child);
            const key_dst = buffer[@sizeOf(InodeSlotHeaderType)..][0..key.len];
            @memcpy(key_dst, key);
        }

        pub fn canInsert(self: *const Self, _: usize, key: []const u8, _: PageIdT) !AvailableStatus {
            const total_size: usize = @sizeOf(InodeSlotHeaderType) + key.len;
            var slot_dir = try self.slotsDir();
            return try slot_dir.canInsert(total_size);
        }

        pub fn canUpdate(self: *const Self, pos: usize, key: []const u8, _: PageIdT) !AvailableStatus {
            const total_size: usize = @sizeOf(InodeSlotHeaderType) + key.len;
            var slot_dir = try self.slotsDir();
            return try slot_dir.canUpdate(pos, total_size);
        }

        pub fn upperBoundWith(
            self: *const Self,
            key: []const u8,
            comptime cmp: anytype, // comparator function fn (ctx, a, b) algorithm.Order
            ctx: anytype, // context for comparator
        ) !usize {
            const Ctx = @TypeOf(ctx);
            const Wrapper = struct {
                slot_dir: ConstSlotsDirType,
                user_ctx: Ctx,

                fn less(wrapper: *const @This(), a: ConstSlotsDirType.Entry, key_b: []const u8) !algorithm.Order {
                    const slot_key = try wrapper.slot_dir.getByEntry(&a);
                    const slot_values = try keyChildFromBuffer(slot_key);
                    return cmp(wrapper.user_ctx, slot_values.key, key_b);
                }
            };

            const slot_dir = try self.slotsDir();
            const wrapper = Wrapper{ .slot_dir = slot_dir, .user_ctx = ctx };
            return try algorithm.upperBound(ConstSlotsDirType.Entry, slot_dir.entriesConst(), key, Wrapper.less, &wrapper);
        }

        pub fn get(self: *const Self, pos: usize) !KeyChild {
            const slot_dir = try self.slotsDir();
            const slot_buffer = try slot_dir.get(pos);
            return keyChildFromBuffer(slot_buffer);
        }
    };

    return struct {
        pub const Slots = SlotsDirType;

        pub const PageViewType = HeaderPageView;

        pub const LeafSubheader = LeafSubheaderType;
        pub const InodeSubheader = InodeSubheaderType;

        pub const LeafSubheaderView = LeafSubheaderViewType;
        pub const InodeSubheaderView = InodeSubheaderViewType;

        pub const InodeSlotHeader = InodeSlotHeaderType;
        pub const LeafSlotHeader = LeafSlotHeaderType;

        pub const SlotsAvailableStatus = ConstSlotsDirType.AvailableStatus;
    };
}
