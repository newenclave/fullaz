const std = @import("std");
const header = @import("../../page/header.zig");
const extensions = @import("../../page/extensions.zig");
const subheaders = @import("../../page/subheader.zig");
const slots = @import("../../slots/variadic.zig");
const links = @import("../../page/links.zig");

const PageView = @import("../../page/header.zig").View;
const errors = @import("../../core/errors.zig");

const conracts = @import("../../contracts/contracts.zig");

pub fn View(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime Endian: std.builtin.Endian,
    comptime read_only: bool,
) type {
    const LinkTrait = links.Trait(PageIdT, Endian);

    const SlotsDirType = slots.VariadicImpl(IndexT, Endian, read_only, 2);
    const SlotsDirTypeMut = slots.VariadicImpl(IndexT, Endian, false, 2);

    const DataType = if (read_only) []const u8 else []u8;

    const Additional = extensions.Compose(.{
        .version = 1,
        .fields = .{
            extensions.field("links", LinkTrait),
        },
    });

    const ChunkSubheader = extern struct {
        reserved: [2]u8,
    };

    const ChunkImpl = struct {
        const Self = @This();
        const SubheaderType = ChunkSubheader;
        const SubheaderView = subheaders.ViewImpl(
            PageIdT,
            IndexT,
            Additional,
            SubheaderType,
            Endian,
            read_only,
        );
        pub const Error = errors.SlotsError;

        view: SubheaderView = undefined,

        pub fn init(data: DataType) Self {
            return .{
                .view = SubheaderView.init(data),
            };
        }

        pub fn formatPage(self: *Self, kind: u16, page_id: PageIdT, metadata_len: IndexT) Error!void {
            if (read_only) {
                @compileError("Cannot format a read-only page");
            }
            self.view.formatPage(kind, page_id, metadata_len);

            var sh = self.view.subheaderMut();
            sh.reserved[0] = 0;
            sh.reserved[1] = 0;

            var sd = try self.slotsDirMut();
            sd.formatHeader();
        }

        pub fn slotsDir(self: *const Self) Error!SlotsDirType {
            const data = self.view.page().data();
            return try SlotsDirType.init(data);
        }

        pub fn slotsDirMut(self: *Self) Error!SlotsDirTypeMut {
            var p = self.view.pageMut();
            const data = p.dataMut();
            return try SlotsDirTypeMut.init(data);
        }

        pub fn setNext(self: *Self, pid: ?PageIdT) void {
            LinkTrait.setNext(&self.view.headerMut().additional.links, pid);
        }

        pub fn getNext(self: *const Self) ?PageIdT {
            return LinkTrait.getNext(&self.view.header().additional.links);
        }

        pub fn setPrev(self: *Self, pid: ?PageIdT) void {
            LinkTrait.setPrev(&self.view.headerMut().additional.links, pid);
        }

        pub fn getPrev(self: *const Self) ?PageIdT {
            return LinkTrait.getPrev(&self.view.header().additional.links);
        }
    };

    return struct {
        pub const Error = ChunkImpl.Error;
        pub const PageId = PageIdT;
        pub const Index = IndexT;
        pub const Chunk = ChunkImpl;
        pub const SlotsDir = SlotsDirType;
    };
}
