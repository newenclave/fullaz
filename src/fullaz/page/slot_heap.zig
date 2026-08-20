const std = @import("std");
const core = @import("../core/core.zig");
const header = @import("header.zig");
const PageSlotRef = @import("page_slot_ref.zig").PageSlotRef;
const fsm_location = @import("../storage/fsm/location.zig");

const PackedInt = core.packed_int.PackedInt;

pub fn LeafPageLocationAccessor(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime Endian: std.builtin.Endian,
) type {
    const Format = SlotHeap(PageIdT, IndexT, Endian);
    const HeaderView = header.View(PageIdT, IndexT, Endian, false);
    const ReadHeaderView = header.View(PageIdT, IndexT, Endian, true);
    const LeafSubheader = Format.LeafSubheader;
    const FsmLocation = Format.FsmLocation;

    return struct {
        pub const Location = FsmLocation.Location;
        pub const Error = ReadHeaderView.Error;

        fn subheader(data: []const u8) Error!*const LeafSubheader {
            const view = ReadHeaderView.init(data);
            try view.validateTyped();
            const page_header = view.header();
            if (@as(usize, @intCast(page_header.subheader_size.get())) != @sizeOf(LeafSubheader) or
                page_header.metadata_size.get() != 0)
            {
                return Error.InconsistentLayout;
            }
            const bytes = view.subheader();
            return @ptrCast(@alignCast(&bytes[0]));
        }

        fn subheaderMut(data: []u8) Error!*LeafSubheader {
            var view = HeaderView.init(data);
            try view.validateTyped();
            const page_header = view.header();
            if (@as(usize, @intCast(page_header.subheader_size.get())) != @sizeOf(LeafSubheader) or
                page_header.metadata_size.get() != 0)
            {
                return Error.InconsistentLayout;
            }
            const bytes = view.subheaderMut();
            return @ptrCast(@alignCast(&bytes[0]));
        }

        pub fn read(data: []const u8) Error!?Location {
            const stored = &(try subheader(data)).fsm_location;
            if (!FsmLocation.validate(stored)) {
                return Error.InconsistentLayout;
            }
            return FsmLocation.get(stored);
        }

        pub fn write(data: []u8, location: Location) Error!void {
            if (location.page_id == std.math.maxInt(PageIdT) or
                location.slot_id == std.math.maxInt(IndexT))
            {
                return Error.InconsistentLayout;
            }
            const stored = &(try subheaderMut(data)).fsm_location;
            FsmLocation.set(stored, location);
        }

        pub fn clear(data: []u8) Error!void {
            const stored = &(try subheaderMut(data)).fsm_location;
            FsmLocation.clear(stored);
        }
    };
}

pub fn SlotHeap(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime Endian: std.builtin.Endian,
) type {
    const format_version: u16 = 1;
    const layout = struct {
        const PackedPageId = PackedInt(PageIdT, Endian);
        const PackedIndex = PackedInt(IndexT, Endian);
        const PackedU16 = PackedInt(u16, Endian);
        const PackedU32 = PackedInt(u32, Endian);
        const StoredLocation = PageSlotRef(PageIdT, IndexT, Endian);
        const FsmLocation = fsm_location.Trait(PageIdT, IndexT, Endian);

        const LeafSubheader = extern struct {
            const Self = @This();

            parent_pid: PackedPageId,
            fsm_location: FsmLocation.Storage,
            format_version: PackedU16,
            key_size: PackedIndex,
            comparator_id: PackedU32,
            reserved: u8,

            pub fn formatHeader(self: *Self, key_size: IndexT, comparator_id: u32) void {
                self.parent_pid.setMax();
                FsmLocation.format(&self.fsm_location);
                self.format_version.set(format_version);
                self.key_size.set(key_size);
                self.comparator_id.set(comparator_id);
                self.reserved = 0;
            }
        };

        const InodeSubheader = extern struct {
            const Self = @This();

            parent_pid: PackedPageId,
            level: PackedIndex,
            available_prev: PackedPageId,
            available_next: PackedPageId,
            format_version: PackedU16,
            key_size: PackedIndex,
            comparator_id: PackedU32,
            available_linked: u8,
            reserved: [3]u8,

            pub fn formatHeader(
                self: *Self,
                level: IndexT,
                key_size: IndexT,
                comparator_id: u32,
            ) void {
                self.parent_pid.setMax();
                self.level.set(level);
                self.available_prev.setMax();
                self.available_next.setMax();
                self.format_version.set(format_version);
                self.key_size.set(key_size);
                self.comparator_id.set(comparator_id);
                self.available_linked = 0;
                self.reserved = [_]u8{0} ** 3;
            }
        };

        // The fixed-size key immediately follows this prefix in every inode slot.
        const InodeSlotHeader = extern struct {
            child_pid: PackedPageId,
            leaf_top: StoredLocation,
        };
    };

    return struct {
        pub const page_format_version = format_version;

        pub const PackedPageId = layout.PackedPageId;
        pub const PackedIndex = layout.PackedIndex;
        pub const Location = layout.FsmLocation.Location;
        pub const StoredLocation = layout.StoredLocation;
        pub const FsmLocation = layout.FsmLocation;

        pub const LeafSubheader = layout.LeafSubheader;
        pub const InodeSubheader = layout.InodeSubheader;
        pub const InodeSlotHeader = layout.InodeSlotHeader;
    };
}
