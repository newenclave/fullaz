const std = @import("std");
const build_options = @import("build_options");
const errors = @import("../../../core/errors.zig");
const header = @import("../../../page/header.zig");
const slot_heap_page = @import("../../../page/slot_heap.zig");
const slots = @import("../../../slots/slots.zig");

pub fn View(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime Endian: std.builtin.Endian,
    comptime read_only: bool,
) type {
    const Format = slot_heap_page.SlotHeap(PageIdT, IndexT, Endian);
    const HeaderView = header.View(PageIdT, IndexT, Endian, read_only);
    const MutableLeafSlots = slots.Variadic(IndexT, Endian, read_only);
    const ConstLeafSlots = slots.Variadic(IndexT, Endian, true);
    const MutableInodeSlots = slots.Fixed(u16, IndexT, Endian, read_only);
    const ConstInodeSlots = slots.Fixed(u16, IndexT, Endian, true);

    const Data = if (read_only) []const u8 else []u8;
    const ErrorSet = HeaderView.Error ||
        MutableLeafSlots.Error ||
        MutableInodeSlots.Error ||
        errors.PageError ||
        error{
            BadKeyLength,
            ComparatorMismatch,
            EmptySet,
        };

    const Location = Format.Location;
    const StoredLocation = Format.StoredLocation;
    const inode_slot_header_size = @sizeOf(Format.InodeSlotHeader);

    const decodeOptionalPid = struct {
        fn call(stored: *const Format.PackedPageId) ?PageIdT {
            return if (stored.isMax()) null else stored.get();
        }
    }.call;

    const encodeOptionalPid = struct {
        fn call(stored: *Format.PackedPageId, value: ?PageIdT) ErrorSet!void {
            if (value) |pid| {
                if (pid == std.math.maxInt(PageIdT)) {
                    return ErrorSet.BadData;
                }
                stored.set(pid);
            } else {
                stored.setMax();
            }
        }
    }.call;

    const decodeRequiredLocation = struct {
        fn call(stored: *const StoredLocation) ErrorSet!Location {
            if (stored.page_id.isMax() or stored.slot_id.isMax()) {
                return ErrorSet.BadData;
            }
            return .{
                .page_id = stored.page_id.get(),
                .slot_id = stored.slot_id.get(),
            };
        }
    }.call;

    const encodeLocation = struct {
        fn call(stored: *StoredLocation, value: Location) void {
            stored.page_id.set(value.page_id);
            stored.slot_id.set(value.slot_id);
        }
    }.call;

    const LeafPageView = struct {
        const Self = @This();
        const subheader_size = @sizeOf(Format.LeafSubheader);

        pub const Entry = struct {
            key: []const u8,
            value: []const u8,
        };

        page: Data,
        page_view: HeaderView,

        pub fn init(data: Data) Self {
            return .{ .page = data, .page_view = HeaderView.init(data) };
        }

        pub fn formatPage(
            self: *Self,
            kind: u16,
            page_id: PageIdT,
            key_size: usize,
            comparator_id: u32,
        ) ErrorSet!void {
            const stored_key_size = std.math.cast(IndexT, key_size) orelse return ErrorSet.BadKeyLength;
            if (stored_key_size == 0) {
                return ErrorSet.BadKeyLength;
            }
            const data_offset = HeaderView.header_size + subheader_size;
            if (data_offset > self.page.len) {
                return ErrorSet.BufferTooSmall;
            }
            _ = try MutableLeafSlots.init(self.page[data_offset..]);
            self.page_view.formatPage(kind, page_id, @intCast(subheader_size), 0);
            self.subheaderMut().formatHeader(stored_key_size, comparator_id);
            var slot_dir = try self.slotsDirMut();
            slot_dir.formatHeader();
        }

        pub fn validatePage(
            self: *const Self,
            page_id: PageIdT,
            kind: u16,
            key_size: usize,
            comparator_id: u32,
        ) ErrorSet!void {
            try self.page_view.validateTyped();
            const page_header = self.page_view.header();
            if (page_header.self_pid.get() != page_id) {
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

            const leaf_header = self.subheader();
            if (leaf_header.format_version.get() != Format.page_format_version) {
                return ErrorSet.UnsupportedVersion;
            }
            if (@as(usize, @intCast(leaf_header.key_size.get())) != key_size or key_size == 0) {
                return ErrorSet.BadData;
            }
            if (leaf_header.comparator_id.get() != comparator_id) {
                return ErrorSet.ComparatorMismatch;
            }
            if (leaf_header.reserved != 0 or !Format.FsmLocation.validate(&leaf_header.fsm_location)) {
                return ErrorSet.BadData;
            }

            const slot_dir = try self.slotsDir();
            if (build_options.full_validation) {
                try slot_dir.validate();
                const entry_count = slot_dir.entries().len;
                var i: usize = 0;
                while (i < entry_count) : (i += 1) {
                    if ((try slot_dir.get(i)).len < key_size) {
                        return ErrorSet.BadData;
                    }
                }
                _ = try slot_dir.usedBytes();
            } else {
                try slot_dir.validateStructural();
            }
        }

        pub fn header(self: *const Self) *const HeaderView.PageHeader {
            return self.page_view.header();
        }

        pub fn subheader(self: *const Self) *const Format.LeafSubheader {
            const bytes = self.page_view.subheader();
            return @ptrCast(@alignCast(&bytes[0]));
        }

        pub fn subheaderMut(self: *Self) *Format.LeafSubheader {
            if (read_only) {
                @compileError("Cannot get a mutable subheader from a read-only page");
            }
            const bytes = self.page_view.subheaderMut();
            return @ptrCast(@alignCast(&bytes[0]));
        }

        pub fn slotsDir(self: *const Self) ErrorSet!ConstLeafSlots {
            return ConstLeafSlots.init(self.page_view.data());
        }

        pub fn slotsDirMut(self: *Self) ErrorSet!MutableLeafSlots {
            if (read_only) {
                @compileError("Cannot get mutable slots from a read-only page");
            }
            return MutableLeafSlots.init(self.page_view.dataMut());
        }

        pub fn getParent(self: *const Self) ?PageIdT {
            return decodeOptionalPid(&self.subheader().parent_pid);
        }

        pub fn setParent(self: *Self, parent: ?PageIdT) ErrorSet!void {
            try encodeOptionalPid(&self.subheaderMut().parent_pid, parent);
        }

        pub fn entries(self: *const Self) ErrorSet!usize {
            return (try self.slotsDir()).entries().len;
        }

        pub fn get(self: *const Self, index: usize) ErrorSet!Entry {
            const bytes = try (try self.slotsDir()).get(index);
            const key_size: usize = @intCast(self.subheader().key_size.get());
            if (bytes.len < key_size) {
                return ErrorSet.BadData;
            }
            return .{
                .key = bytes[0..key_size],
                .value = bytes[key_size..],
            };
        }

        pub fn canAppend(self: *const Self, value_len: usize) ErrorSet!ConstLeafSlots.AvailableStatus {
            const key_size: usize = @intCast(self.subheader().key_size.get());
            const slot_len = std.math.add(usize, key_size, value_len) catch return .not_enough;
            if (std.math.cast(IndexT, slot_len) == null) {
                return .not_enough;
            }
            return (try self.slotsDir()).canInsert(slot_len);
        }

        pub fn append(self: *Self, key: []const u8, value: []const u8) ErrorSet!usize {
            const key_size: usize = @intCast(self.subheader().key_size.get());
            if (key.len != key_size) {
                return ErrorSet.BadKeyLength;
            }
            const slot_len = std.math.add(usize, key.len, value.len) catch {
                return ErrorSet.NotEnoughSpace;
            };
            if (std.math.cast(IndexT, slot_len) == null) {
                return ErrorSet.NotEnoughSpace;
            }
            var slot_dir = try self.slotsDirMut();
            if (build_options.full_validation) {
                try slot_dir.validate();
            } else {
                try slot_dir.validateStructural();
            }
            const index = slot_dir.entries().len;
            const bytes = try slot_dir.reserveGetAt(index, slot_len);
            @memcpy(bytes[0..key.len], key);
            @memcpy(bytes[key.len..][0..value.len], value);
            return index;
        }

        pub fn swapEntries(self: *Self, a: usize, b: usize) ErrorSet!void {
            var slot_dir = try self.slotsDirMut();
            try slot_dir.swapEntries(a, b);
        }

        pub fn removeLast(self: *Self) ErrorSet!void {
            var slot_dir = try self.slotsDirMut();
            const count = slot_dir.entries().len;
            if (count == 0) {
                return ErrorSet.EmptySet;
            }
            try slot_dir.remove(count - 1);
        }

        pub fn compact(self: *Self, scratch: []u8) ErrorSet!void {
            var slot_dir = try self.slotsDirMut();
            try slot_dir.compactWithBuffer(scratch);
        }

        pub fn compactInPlace(self: *Self) ErrorSet!void {
            var slot_dir = try self.slotsDirMut();
            try slot_dir.compactInPlace();
        }

        pub fn availableAfterCompact(self: *const Self) ErrorSet!usize {
            return (try self.slotsDir()).availableAfterCompact();
        }

        pub fn usedBytes(self: *const Self) ErrorSet!usize {
            return (try self.slotsDir()).usedBytes();
        }

        pub fn capacityBytes(self: *const Self) ErrorSet!usize {
            return (try self.slotsDir()).capacitySpace();
        }
    };

    const InodePageView = struct {
        const Self = @This();
        const subheader_size = @sizeOf(Format.InodeSubheader);

        pub const Entry = struct {
            key: []const u8,
            child_pid: PageIdT,
            leaf_top: Location,
        };

        page: Data,
        page_view: HeaderView,

        pub fn init(data: Data) Self {
            return .{ .page = data, .page_view = HeaderView.init(data) };
        }

        pub fn inodeSlotSize(key_size: usize) usize {
            return inode_slot_header_size + key_size;
        }

        pub fn formatPage(
            self: *Self,
            kind: u16,
            page_id: PageIdT,
            level: usize,
            key_size: usize,
            comparator_id: u32,
        ) ErrorSet!void {
            const stored_level = std.math.cast(IndexT, level) orelse return ErrorSet.BadData;
            const stored_key_size = std.math.cast(IndexT, key_size) orelse return ErrorSet.BadKeyLength;
            if (stored_level == 0 or stored_key_size == 0) {
                return ErrorSet.BadData;
            }
            const slot_size = std.math.add(usize, inode_slot_header_size, key_size) catch {
                return ErrorSet.BadKeyLength;
            };
            if (std.math.cast(IndexT, slot_size) == null) {
                return ErrorSet.BadKeyLength;
            }
            const data_offset = HeaderView.header_size + subheader_size;
            if (data_offset > self.page.len) {
                return ErrorSet.BufferTooSmall;
            }
            _ = try MutableInodeSlots.init(self.page[data_offset..]);
            self.page_view.formatPage(kind, page_id, @intCast(subheader_size), 0);
            self.subheaderMut().formatHeader(stored_level, stored_key_size, comparator_id);
            var slot_dir = try self.slotsDirMut();
            try slot_dir.format(slot_size);
        }

        pub fn validatePage(
            self: *const Self,
            page_id: PageIdT,
            kind: u16,
            key_size: usize,
            comparator_id: u32,
        ) ErrorSet!void {
            try self.page_view.validateTyped();
            const page_header = self.page_view.header();
            if (page_header.self_pid.get() != page_id) {
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

            const inode_header = self.subheader();
            if (inode_header.format_version.get() != Format.page_format_version) {
                return ErrorSet.UnsupportedVersion;
            }
            if (@as(usize, @intCast(inode_header.key_size.get())) != key_size or key_size == 0) {
                return ErrorSet.BadData;
            }
            if (inode_header.comparator_id.get() != comparator_id) {
                return ErrorSet.ComparatorMismatch;
            }
            if (inode_header.level.get() == 0 or inode_header.available_linked > 1 or
                !std.mem.eql(u8, &inode_header.reserved, &[_]u8{ 0, 0, 0 }))
            {
                return ErrorSet.BadData;
            }
            if (inode_header.available_linked == 0 and
                (!inode_header.available_prev.isMax() or !inode_header.available_next.isMax()))
            {
                return ErrorSet.BadData;
            }

            const slot_dir = try self.slotsDir();
            try slot_dir.validate();
            const expected_slot_size = std.math.add(usize, inode_slot_header_size, key_size) catch {
                return ErrorSet.BadData;
            };
            if (try slot_dir.slotSize() != expected_slot_size) {
                return ErrorSet.BadData;
            }
            if (build_options.full_validation) {
                const count = try slot_dir.size();
                const slot_capacity = try slot_dir.capacity();
                var i: usize = 0;
                while (i < slot_capacity) : (i += 1) {
                    if ((try slot_dir.isSet(i)) != (i < count)) {
                        return ErrorSet.BadData;
                    }
                }
                i = 0;
                while (i < count) : (i += 1) {
                    _ = try self.get(i);
                }
            }
        }

        pub fn header(self: *const Self) *const HeaderView.PageHeader {
            return self.page_view.header();
        }

        pub fn subheader(self: *const Self) *const Format.InodeSubheader {
            const bytes = self.page_view.subheader();
            return @ptrCast(@alignCast(&bytes[0]));
        }

        pub fn subheaderMut(self: *Self) *Format.InodeSubheader {
            if (read_only) {
                @compileError("Cannot get a mutable subheader from a read-only page");
            }
            const bytes = self.page_view.subheaderMut();
            return @ptrCast(@alignCast(&bytes[0]));
        }

        pub fn slotsDir(self: *const Self) ErrorSet!ConstInodeSlots {
            return ConstInodeSlots.init(self.page_view.data());
        }

        pub fn slotsDirMut(self: *Self) ErrorSet!MutableInodeSlots {
            if (read_only) {
                @compileError("Cannot get mutable slots from a read-only page");
            }
            return MutableInodeSlots.init(self.page_view.dataMut());
        }

        pub fn getParent(self: *const Self) ?PageIdT {
            return decodeOptionalPid(&self.subheader().parent_pid);
        }

        pub fn setParent(self: *Self, parent: ?PageIdT) ErrorSet!void {
            try encodeOptionalPid(&self.subheaderMut().parent_pid, parent);
        }

        pub fn getLevel(self: *const Self) usize {
            return @intCast(self.subheader().level.get());
        }

        pub fn getAvailablePrev(self: *const Self) ?PageIdT {
            return decodeOptionalPid(&self.subheader().available_prev);
        }

        pub fn setAvailablePrev(self: *Self, previous: ?PageIdT) ErrorSet!void {
            try encodeOptionalPid(&self.subheaderMut().available_prev, previous);
        }

        pub fn getAvailableNext(self: *const Self) ?PageIdT {
            return decodeOptionalPid(&self.subheader().available_next);
        }

        pub fn setAvailableNext(self: *Self, next: ?PageIdT) ErrorSet!void {
            try encodeOptionalPid(&self.subheaderMut().available_next, next);
        }

        pub fn isAvailableLinked(self: *const Self) bool {
            return self.subheader().available_linked != 0;
        }

        pub fn setAvailableLinked(self: *Self, linked: bool) void {
            self.subheaderMut().available_linked = @intFromBool(linked);
        }

        pub fn entries(self: *const Self) ErrorSet!usize {
            return (try self.slotsDir()).size();
        }

        pub fn capacity(self: *const Self) ErrorSet!usize {
            return (try self.slotsDir()).capacity();
        }

        pub fn get(self: *const Self, index: usize) ErrorSet!Entry {
            const bytes = try (try self.slotsDir()).get(index);
            const key_size: usize = @intCast(self.subheader().key_size.get());
            if (bytes.len != inodeSlotSize(key_size)) {
                return ErrorSet.BadData;
            }
            const slot_header: *const Format.InodeSlotHeader = @ptrCast(@alignCast(&bytes[0]));
            if (slot_header.child_pid.isMax()) {
                return ErrorSet.BadData;
            }
            return .{
                .key = bytes[inode_slot_header_size..],
                .child_pid = slot_header.child_pid.get(),
                .leaf_top = try decodeRequiredLocation(&slot_header.leaf_top),
            };
        }

        pub fn findChild(self: *const Self, child_pid: PageIdT) ErrorSet!?usize {
            const count = try self.entries();
            var i: usize = 0;
            while (i < count) : (i += 1) {
                if ((try self.get(i)).child_pid == child_pid) {
                    return i;
                }
            }
            return null;
        }

        pub fn append(
            self: *Self,
            key: []const u8,
            child_pid: PageIdT,
            leaf_top: Location,
        ) ErrorSet!usize {
            const key_size: usize = @intCast(self.subheader().key_size.get());
            if (key.len != key_size) {
                return ErrorSet.BadKeyLength;
            }
            if (child_pid == std.math.maxInt(PageIdT) or
                leaf_top.page_id == std.math.maxInt(PageIdT) or
                leaf_top.slot_id == std.math.maxInt(IndexT))
            {
                return ErrorSet.BadData;
            }
            var slot_dir = try self.slotsDirMut();
            try slot_dir.validate();
            const count = try slot_dir.size();
            if (count >= try slot_dir.capacity()) {
                return ErrorSet.NotEnoughSpace;
            }
            try slot_dir.set(count, &.{});
            errdefer slot_dir.free(count) catch {};
            try self.setEntry(count, key, child_pid, leaf_top);
            return count;
        }

        pub fn setEntry(
            self: *Self,
            index: usize,
            key: []const u8,
            child_pid: PageIdT,
            leaf_top: Location,
        ) ErrorSet!void {
            const key_size: usize = @intCast(self.subheader().key_size.get());
            if (key.len != key_size) {
                return ErrorSet.BadKeyLength;
            }
            if (child_pid == std.math.maxInt(PageIdT) or
                leaf_top.page_id == std.math.maxInt(PageIdT) or
                leaf_top.slot_id == std.math.maxInt(IndexT))
            {
                return ErrorSet.BadData;
            }
            var slot_dir = try self.slotsDirMut();
            try slot_dir.validate();
            const bytes = try slot_dir.getMut(index);
            if (bytes.len != inodeSlotSize(key_size)) {
                return ErrorSet.BadData;
            }
            const slot_header: *Format.InodeSlotHeader = @ptrCast(@alignCast(&bytes[0]));
            slot_header.child_pid.set(child_pid);
            encodeLocation(&slot_header.leaf_top, leaf_top);
            const stored_key = bytes[inode_slot_header_size..];
            const stored_address = @intFromPtr(stored_key.ptr);
            const source_address = @intFromPtr(key.ptr);
            if (stored_address < source_address) {
                std.mem.copyForwards(u8, stored_key, key);
            } else if (stored_address > source_address) {
                std.mem.copyBackwards(u8, stored_key, key);
            }
        }

        pub fn swapEntries(self: *Self, a: usize, b: usize) ErrorSet!void {
            var slot_dir = try self.slotsDirMut();
            try slot_dir.swapUsed(a, b);
        }

        pub fn removeLast(self: *Self) ErrorSet!void {
            var slot_dir = try self.slotsDirMut();
            const count = try slot_dir.size();
            if (count == 0) {
                return ErrorSet.EmptySet;
            }
            try slot_dir.free(count - 1);
        }
    };

    return struct {
        pub const Error = ErrorSet;
        pub const full_validation_enabled = build_options.full_validation;
        pub const LocationType = Location;
        pub const FormatType = Format;
        pub const Leaf = LeafPageView;
        pub const Inode = InodePageView;
    };
}
