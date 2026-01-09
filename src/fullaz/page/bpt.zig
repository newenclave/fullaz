const std = @import("std");
const header = @import("header.zig");
const SubheaderView = @import("subheader.zig").View;
const PackedInt = @import("../packed_int.zig").PackedInt;
const slots = @import("../slots/slots.zig");

pub fn Bpt(comptime PageIdT: type, comptime IndexT: type, comptime Endian: std.builtin.Endian, comptime read_only: bool) type {
    const PageIdType = PackedInt(PageIdT, Endian);
    const IndexType = PackedInt(IndexT, Endian);

    const HeaderPageView = header.View(PageIdT, IndexT, Endian, read_only);

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

    const LeafSubheaderViewType = struct {
        const Self = @This();
        const DataType = if (read_only) []const u8 else []u8;
        const PageViewType = HeaderPageView;
        const Slots = slots.Variadic(IndexT, Endian, read_only);

        page_view: PageViewType,

        pub fn init(data: DataType) Self {
            return .{
                .page_view = PageViewType.init(data),
            };
        }

        pub fn page(self: *const Self) DataType {
            return self.page_view.page;
        }

        pub fn formatPage(self: *Self, kind: u16, page_id: PageIdT, metadata_len: IndexT) !void {
            self.page_view.formatPage(kind, page_id, @as(IndexT, @intCast(@sizeOf(LeafSubheaderType))), metadata_len);
            const data = self.page_view.dataMut();
            var sl = try Slots.init(data);
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

        pub fn slotsDir(self: *Self) !Slots {
            const data = self.page_view.dataMut();
            return try Slots.init(data);
        }
    };

    const LeafSlotHeaderType = extern struct {
        key_size: IndexType,
    };

    const InodeSubheaderType = extern struct {
        parent: PageIdType,
        rightmost_child: PageIdType,
    };

    const InodeSubheaderViewType = struct {
        const Self = @This();
        const DataType = if (read_only) []const u8 else []u8;
        const PageViewType = HeaderPageView;
        const Slots = slots.Variadic(IndexT, Endian, read_only);

        page_view: PageViewType,

        pub fn init(data: DataType) Self {
            return .{
                .page_view = PageViewType.init(data),
            };
        }

        pub fn page(self: *const Self) DataType {
            return self.page_view.page;
        }

        pub fn formatPage(self: *Self, kind: u16, page_id: PageIdT, metadata_len: IndexT) !void {
            self.page_view.formatPage(kind, page_id, @as(IndexT, @intCast(@sizeOf(InodeSubheaderType))), metadata_len);

            const data = self.page_view.dataMut();
            var sl = try Slots.init(data);
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

        pub fn slotsDir(self: *Self) !Slots {
            const data = self.page_view.dataMut();
            return try Slots.init(data);
        }
    };

    const InodeSlotHeaderType = extern struct {
        child: PageIdType,
    };

    return struct {
        pub const Slots = slots.Variadic(IndexT, Endian, read_only);

        pub const PageViewType = HeaderPageView;

        pub const LeafSubheader = LeafSubheaderType;
        pub const InodeSubheader = InodeSubheaderType;

        pub const LeafSubheaderView = LeafSubheaderViewType;
        pub const InodeSubheaderView = InodeSubheaderViewType;

        pub const InodeSlotHeader = InodeSlotHeaderType;
        pub const LeafSlotHeader = LeafSlotHeaderType;
    };
}
