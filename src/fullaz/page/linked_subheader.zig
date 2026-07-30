const std = @import("std");
const PackedInt = @import("../core/core.zig").packed_int.PackedInt;
const header = @import("header.zig");
const subheader = @import("subheader.zig");
const PageViewType = @import("header.zig").View;

pub fn LinkedSubheader(
    comptime PageIdT: type,
    comptime SubheaderT: type,
    comptime Endian: std.builtin.Endian,
) type {
    const PageIdPacked = PackedInt(PageIdT, Endian);
    const has_subheader = @TypeOf(SubheaderT) != void;
    const SubheaderType = if (has_subheader) SubheaderT else PackedInt(u16, Endian);

    const SubheaderImpl = extern struct {
        const Self = @This();
        back: PageIdPacked,
        fwd: PageIdPacked,
        subheader: SubheaderType,

        pub fn format(self: *Self) void {
            self.fwd.format();
            self.back.format();
        }
    };

    return struct {
        pub const PageIdType = PageIdPacked;
        pub const Subheader = SubheaderImpl;
    };
}

pub fn View(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime Subheader: type,
    comptime Endian: std.builtin.Endian,
    comptime read_only: bool,
) type {
    const LinkedSubheaderType = LinkedSubheader(PageIdT, Subheader, Endian).Subheader;

    return struct {
        const Self = @This();

        const DataType = if (read_only) []const u8 else []u8;

        pub const has_subheader = (@TypeOf(Subheader) != void);

        pub const PageView = PageViewType(PageIdT, IndexT, Endian, read_only);
        pub const linked_subheader_size = @sizeOf(LinkedSubheaderType);
        pub const subheader_size = @sizeOf(Subheader);

        page_view: PageView,

        pub fn init(data: DataType) Self {
            return .{
                .page_view = PageView.init(data),
            };
        }

        pub fn page(self: *const Self) PageView {
            return self.page_view;
        }

        pub fn pageMut(self: *Self) PageView {
            if (read_only) {
                @compileError("Cannot get mutable page from a read-only view");
            }
            return self.page_view;
        }

        pub fn formatPage(self: *Self, kind: u16, page_id: PageIdT, metadata_len: IndexT) void {
            self.page_view.formatPage(
                kind,
                page_id,
                @as(IndexT, @intCast(linked_subheader_size)),
                metadata_len,
            );
        }

        pub fn getBack(self: *const Self) ?PageIdT {
            const linked = self.linkedSubheader();
            if (linked.back.isMax()) {
                return null;
            } else {
                return linked.back.get();
            }
        }

        pub fn getFwd(self: *const Self) ?PageIdT {
            const linked = self.linkedSubheader();
            if (linked.fwd.isMax()) {
                return null;
            } else {
                return linked.fwd.get();
            }
        }

        pub fn setBack(self: *Self, back: ?PageIdT) void {
            if (read_only) {
                @compileError("Cannot set back on a read-only view");
            }
            const linked = self.linkedSubheaderMut();
            if (back) |b| {
                linked.back.set(b);
            } else {
                linked.back.setMax();
            }
        }

        pub fn setFwd(self: *Self, fwd: ?PageIdT) void {
            if (read_only) {
                @compileError("Cannot set next on a read-only view");
            }
            const linked = self.linkedSubheaderMut();
            if (fwd) |f| {
                linked.fwd.set(f);
            } else {
                linked.fwd.setMax();
            }
        }

        pub fn subheader(self: *const Self) *const Subheader {
            if (!Self.has_subheader) {
                @compileError("Subheader type is void, cannot get subheader");
            }
            const linked = self.linkedSubheader();
            return &linked.subheader;
        }

        pub fn subheaderMut(self: *Self) *Subheader {
            if (!Self.has_subheader) {
                @compileError("Subheader type is void, cannot get subheader");
            }
            if (read_only) {
                @compileError("Cannot get mutable subheader from a read-only page");
            }
            const linked = self.linkedSubheaderMut();
            return &linked.subheader;
        }

        fn linkedSubheader(self: *const Self) *const LinkedSubheaderType {
            const subhdr = self.page_view.subheader();
            return @ptrCast(@alignCast(&subhdr[0]));
        }

        fn linkedSubheaderMut(self: *Self) *LinkedSubheaderType {
            if (read_only) {
                @compileError("Cannot get mutable linked subheader from a read-only page");
            }
            const subhdr = self.page_view.subheaderMut();
            return @ptrCast(@alignCast(&subhdr[0]));
        }
    };
}
