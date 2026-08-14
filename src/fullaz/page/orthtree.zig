const std = @import("std");
const core = @import("../core/core.zig");
const header = @import("header.zig");
const PageSlotRef = @import("page_slot_ref.zig").PageSlotRef;
const PackedInt = core.packed_int.PackedInt;
const PackedNumber = core.packed_int.PackedNumber;

pub fn NodeId(comptime PageIdT: type, comptime SlotIdT: type) type {
    return struct {
        page_id: PageIdT,
        slot_id: SlotIdT,
    };
}

pub fn NodePageLocationAccessor(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime Endian: std.builtin.Endian,
) type {
    const Format = Orthtree(PageIdT, IndexT, u8, 1, Endian);
    const HeaderView = header.View(PageIdT, IndexT, Endian, false);
    const ReadHeaderView = header.View(PageIdT, IndexT, Endian, true);
    const NodePageSubheader = Format.NodePageSubheader;

    return struct {
        pub const Location = NodeId(PageIdT, IndexT);
        pub const Error = ReadHeaderView.Error;

        fn subheader(data: []const u8) Error!*const NodePageSubheader {
            const view = ReadHeaderView.init(data);
            try view.validateTyped();
            const page_header = view.header();
            if (@as(usize, @intCast(page_header.subheader_size.get())) != @sizeOf(NodePageSubheader) or
                page_header.metadata_size.get() != 0)
            {
                return Error.InconsistentLayout;
            }
            const bytes = view.subheader();
            return @ptrCast(@alignCast(&bytes[0]));
        }

        fn subheaderMut(data: []u8) Error!*NodePageSubheader {
            var view = HeaderView.init(data);
            try view.validateTyped();
            const page_header = view.header();
            if (@as(usize, @intCast(page_header.subheader_size.get())) != @sizeOf(NodePageSubheader) or
                page_header.metadata_size.get() != 0)
            {
                return Error.InconsistentLayout;
            }
            const bytes = view.subheaderMut();
            return @ptrCast(@alignCast(&bytes[0]));
        }

        pub fn read(data: []const u8) Error!?Location {
            const stored = (try subheader(data)).fsm_location;
            if (stored.page_id.isMax() != stored.slot_id.isMax()) {
                return Error.InconsistentLayout;
            }
            if (stored.page_id.isMax()) {
                return null;
            }
            return .{
                .page_id = stored.page_id.get(),
                .slot_id = stored.slot_id.get(),
            };
        }

        pub fn write(data: []u8, location: Location) Error!void {
            var stored = try subheaderMut(data);
            stored.fsm_location.page_id.set(location.page_id);
            stored.fsm_location.slot_id.set(location.slot_id);
        }

        pub fn clear(data: []u8) Error!void {
            var stored = try subheaderMut(data);
            stored.fsm_location.format();
        }
    };
}

pub fn Orthtree(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime CoordT: type,
    comptime dims: usize,
    comptime Endian: std.builtin.Endian,
) type {
    comptime {
        if (dims == 0) {
            @compileError("Orthtree requires at least one dimension");
        }
        if (dims >= @bitSizeOf(usize)) {
            @compileError("Orthtree dimension exceeds addressable child count");
        }
    }

    const child_count = 1 << dims;
    const PackedPageId = PackedInt(PageIdT, Endian);
    const IndexType = PackedInt(IndexT, Endian);
    const EntryCountType = PackedInt(u32, Endian);
    const CoordType = PackedNumber(CoordT, Endian);
    const NodeRefType = PageSlotRef(PageIdT, IndexT, Endian);
    const NativeNodeId = NodeId(PageIdT, IndexT);
    const LayoutIdType = PackedInt(u32, Endian);

    const MbrType = extern struct {
        low: [dims]CoordType,
        high: [dims]CoordType,
    };

    const NodeFlagsType = struct {
        pub const internal: u8 = 1 << 0;
    };

    const NodeSubheaderType = extern struct {
        const Self = @This();

        parent: PackedPageId,
        entries_first: PackedPageId,
        entries_last: PackedPageId,
        entries_count: EntryCountType,
        level: u8,
        flags: u8,
        reserved: [2]u8,
        bounds: MbrType,
        children: [child_count]PackedPageId,

        pub fn formatHeader(self: *Self) void {
            self.parent.setMax();
            self.entries_first.setMax();
            self.entries_last.setMax();
            self.entries_count.set(0);
            self.level = 0;
            self.flags = 0;
            self.reserved = .{0} ** 2;
            inline for (0..dims) |axis| {
                self.bounds.low[axis].set(0);
                self.bounds.high[axis].set(0);
            }
            inline for (0..child_count) |index| {
                self.children[index].setMax();
            }
        }
    };

    const node_page_format_version_v: u8 = 1;

    const NodePageSubheaderType = extern struct {
        const Self = @This();

        fsm_location: NodeRefType,
        layout_id: LayoutIdType,
        slot_size: IndexType,
        format_version: u8,
        reserved: u8,

        pub fn formatHeader(self: *Self, layout_id: u32, slot_size: IndexT) void {
            self.fsm_location.format();
            self.layout_id.set(layout_id);
            self.slot_size.set(slot_size);
            self.format_version = node_page_format_version_v;
            self.reserved = 0;
        }
    };

    const NodeSlotSubheaderType = extern struct {
        const Self = @This();

        parent: NodeRefType,
        entries_first: PackedPageId,
        entries_last: PackedPageId,
        entries_count: EntryCountType,
        level: u8,
        flags: u8,
        reserved: [2]u8,
        bounds: MbrType,
        children: [child_count]NodeRefType,

        pub fn formatHeader(self: *Self) void {
            self.parent.format();
            self.entries_first.setMax();
            self.entries_last.setMax();
            self.entries_count.set(0);
            self.level = 0;
            self.flags = 0;
            self.reserved = .{0} ** 2;
            inline for (0..dims) |axis| {
                self.bounds.low[axis].set(0);
                self.bounds.high[axis].set(0);
            }
            inline for (0..child_count) |index| {
                self.children[index].format();
            }
        }
    };

    // Value bytes trail this fixed bounding-box prefix in a slot-chain entry.
    const EntrySlotHeaderType = extern struct {
        bounds: MbrType,
    };

    return struct {
        pub const PageId = PackedPageId;
        pub const Index = IndexType;
        pub const NodeRef = NodeRefType;
        pub const NodeId = NativeNodeId;
        pub const EntryCount = EntryCountType;
        pub const Coord = CoordType;
        pub const dimensions = dims;
        pub const children_per_node = child_count;
        pub const node_page_format_version = node_page_format_version_v;

        pub const Mbr = MbrType;
        pub const NodeFlags = NodeFlagsType;
        pub const NodeSubheader = NodeSubheaderType;
        pub const NodePageSubheader = NodePageSubheaderType;
        pub const NodeSlotSubheader = NodeSlotSubheaderType;
        pub const EntrySlotHeader = EntrySlotHeaderType;
    };
}
