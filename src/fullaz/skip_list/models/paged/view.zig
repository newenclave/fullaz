const std = @import("std");
const header = @import("../../../page/header.zig");
const slots = @import("../../../slots/variadic.zig");
const errors = @import("../../../core/errors.zig");

const SkipListPage = @import("../../../page/skip_list.zig").SkipList;

fn SlotWrapperView(comptime PageIdT: type, comptime IndexT: type, comptime Endian: std.builtin.Endian, comptime read_only: bool) type {
    const SlotsDirType = slots.Variadic(IndexT, Endian, read_only);

    return struct {
        const Self = @This();

        const ByteSlice = if (read_only) []const u8 else []u8;
        const LevelRefBuf = if (read_only) []const LevelRef else []LevelRef;

        const SkipListPageType = SkipListPage(PageIdT, IndexT, Endian);

        const SlotHeader = SkipListPageType.SkipListNode;
        const LevelRef = SkipListPageType.LevelRef;

        const ErrorSet = SlotsDirType.Error;

        slotBody: ByteSlice,
        levels: LevelRefBuf,
        key: ByteSlice,
        value: ByteSlice,

        pub fn init(slotBody: ByteSlice) ErrorSet!Self {
            return checkGet(slotBody);
        }

        pub fn header(self: *const Self) *const SlotHeader {
            return @ptrCast(self.slotBody.ptr);
        }

        pub fn headerMut(self: *Self) *SlotHeader {
            return @ptrCast(self.slotBody.ptr);
        }

        pub fn body(self: *const Self) ByteSlice {
            return self.slotBody;
        }

        fn totalSlotSize(key_len: usize, value_len: usize, level: usize) usize {
            const levelsSize = (level + 1) * @sizeOf(LevelRef);
            return key_len + value_len + @sizeOf(SlotHeader) + levelsSize;
        }

        pub fn levelOffset() usize {
            return @sizeOf(SlotHeader);
        }

        pub fn keyOffset(slot: []const u8) ErrorSet!usize {
            const slotLen = slot.len;

            if (slotLen < @sizeOf(SlotHeader)) {
                return ErrorSet.BufferTooSmall;
            }
            const hdr: *const SlotHeader = @ptrCast(slot);
            const total = totalSlotSize(hdr.key_len.get(), hdr.value_len.get(), @intCast(hdr.level));
            if (slotLen < total) {
                return ErrorSet.BufferTooSmall;
            }
            const levelsSize: usize = (hdr.level + 1) * @sizeOf(LevelRef);
            return @sizeOf(SlotHeader) + levelsSize;
        }

        pub fn valueOffset(slot: []const u8) ErrorSet!usize {
            const keyOff = try keyOffset(slot);
            const hdr: *const SlotHeader = @ptrCast(slot);
            return keyOff + @as(usize, @intCast(hdr.key_len.get()));
        }

        fn checkGet(slot: ByteSlice) ErrorSet!Self {
            if (slot.len < @sizeOf(SlotHeader)) {
                return ErrorSet.BufferTooSmall;
            }
            const hdr: *const SlotHeader = @ptrCast(slot.ptr);

            const keySz: usize = @intCast(hdr.key_len.get());
            const valSz: usize = @intCast(hdr.value_len.get());

            const total = totalSlotSize(keySz, valSz, @intCast(hdr.level));
            if (total > slot.len) {
                return ErrorSet.BufferTooSmall;
            }
            const lvlOff = levelOffset();
            const keyOff = try keyOffset(slot);
            const valOff = try valueOffset(slot);
            const levelsBuf = std.mem.bytesAsSlice(LevelRef, slot[lvlOff..keyOff]);
            return .{
                .slotBody = slot[0..total],
                .levels = levelsBuf,
                .key = slot[keyOff..valOff],
                .value = slot[valOff .. valOff + valSz],
            };
        }
    };
}

pub fn View(comptime PageIdT: type, comptime IndexT: type, comptime Endian: std.builtin.Endian, comptime read_only: bool) type {
    const HeaderPageView = header.View(PageIdT, IndexT, Endian, read_only);
    const SlotsDirType = slots.Variadic(IndexT, Endian, read_only);

    const ConstSlotsDirType = slots.Variadic(IndexT, Endian, true);
    const AvailableStatus = ConstSlotsDirType.AvailableStatus;

    return struct {
        const Self = @This();

        const ByteSlice = if (read_only) []const u8 else []u8;
        const ByteSliceConst = []const u8;
        const ByteSliceMut = []u8;

        const PageViewType = HeaderPageView;
        const ErrorSet = SlotsDirType.Error;

        const SubheaderType = SkipListPage(PageIdT, IndexT, Endian).SkipListSubheader;
        const SlotHeaderType = SkipListPage(PageIdT, IndexT, Endian).SkipListNode;

        pub const KeyType = ByteSlice;
        pub const ValueType = ByteSlice;
        pub const Error = ErrorSet;

        pub const SlotWrapper = SlotWrapperView(PageIdT, IndexT, Endian, read_only);
        pub const SlotWrapperConst = SlotWrapperView(PageIdT, IndexT, Endian, true);
        pub const SlotWrapperMut = SlotWrapperView(PageIdT, IndexT, Endian, false);

        page_view: PageViewType,

        pub fn init(data: ByteSlice) Self {
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

        pub fn page(self: *const Self) ByteSlice {
            return self.page_view.page;
        }

        pub fn entries(self: *const Self) Error!usize {
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

        pub fn slotWrapper(_: *const Self, slot: ByteSlice) ErrorSet!SlotWrapper {
            return try SlotWrapper.init(slot);
        }

        pub fn get(self: *const Self, pos: usize) Error!SlotWrapperConst {
            const sdir = try self.slotsDir();
            const slot = try sdir.get(pos);
            return try SlotWrapperConst.init(slot);
        }

        pub fn getMut(self: *const Self, pos: usize) Error!SlotWrapperMut {
            const sdir = try self.slotsDirMut();
            const slot = try sdir.getMut(pos);
            return try SlotWrapperMut.init(slot);
        }

        pub fn canInsertSize(self: *const Self, pos: usize, value: usize) ErrorSet!AvailableStatus {
            _ = pos;
            return (try self.slotsDir()).canInsert(value);
        }

        pub fn canInsert(self: *const Self, pos: usize, key: []const u8, value: []const u8, level: usize) ErrorSet!AvailableStatus {
            _ = pos;
            const total_len = SlotWrapperConst.totalSlotSize(key.len, value.len, level);
            return (try self.slotsDir()).canInsert(total_len);
        }

        pub fn insert(self: *Self, pos: usize, value: ByteSliceConst) ErrorSet!void {
            var sdir = try self.slotsDirMut();
            try sdir.insertAt(pos, value);
        }

        pub fn canUpdate(self: *const Self, pos: usize, key: []const u8, value: []const u8) Error!AvailableStatus {
            var slot_dir = try self.slotsDir();
            const sw = try self.get(pos);
            const total_size: usize = sw.body().len - sw.key.len - sw.value.len + key.len + value.len;
            return try slot_dir.canUpdate(pos, total_size);
        }

        pub fn createSlot(_: *const Self, buf: []u8, key_size: usize, value_size: usize, levels: usize) ErrorSet!SlotWrapperMut {
            const targetTotal = SlotWrapper.totalSlotSize(key_size, value_size, levels);
            if (buf.len < targetTotal) {
                return ErrorSet.BufferTooSmall;
            }
            var hdr: *SlotHeaderType = @ptrCast(buf.ptr);
            hdr.key_len.set(@intCast(key_size));
            hdr.value_len.set(@intCast(value_size));
            hdr.level = @intCast(levels);
            return try SlotWrapperMut.init(buf);
        }
    };
}
