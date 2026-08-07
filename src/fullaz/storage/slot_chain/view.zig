const std = @import("std");
const header = @import("../../page/header.zig");
const extensions = @import("../../page/extensions.zig");
const subheaders = @import("../../page/subheader.zig");
const slots = @import("../../slots/variadic.zig");
const links = @import("../../page/links.zig");
const page_chain = @import("../page_chain/page_chain.zig");

const PageView = @import("../../page/header.zig").View;
const errors = @import("../../core/errors.zig");

const conracts = @import("../../contracts/contracts.zig");

pub fn View(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime Endian: std.builtin.Endian,
    comptime read_only: bool,
) type {
    return ViewImpl(
        PageIdT,
        IndexT,
        void,
        Endian,
        read_only,
    );
}

pub fn ViewImpl(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime AdditionalT: type,
    comptime Endian: std.builtin.Endian,
    comptime read_only: bool,
) type {
    const SlotsDirType = slots.VariadicImpl(IndexT, Endian, read_only, 2);
    const SlotsDirTypeMut = slots.VariadicImpl(IndexT, Endian, false, 2);

    const PageChainView = page_chain.ViewImpl(
        PageIdT,
        IndexT,
        AdditionalT,
        Endian,
        false,
    );

    const DataType = if (read_only) []const u8 else []u8;

    const ChunkImpl = struct {
        const Self = @This();

        const SubheaderView = page_chain.ViewImpl(
            PageIdT,
            IndexT,
            AdditionalT,
            Endian,
            read_only,
        ).Chunk;
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
            self.view.formatPage(kind, page_id, 0, metadata_len);

            var sd = try self.slotsDirMut();
            sd.formatHeader();
        }

        pub fn slotsDir(self: *const Self) Error!SlotsDirType {
            const data = self.view.data();
            return try SlotsDirType.init(data);
        }

        pub fn slotsDirMut(self: *Self) Error!SlotsDirTypeMut {
            const data = self.view.dataMut();
            return try SlotsDirTypeMut.init(data);
        }

        pub fn setNext(self: *Self, pid: ?PageIdT) void {
            self.view.setNext(pid);
        }

        pub fn getNext(self: *const Self) ?PageIdT {
            return self.view.getNext();
        }

        pub fn setPrev(self: *Self, pid: ?PageIdT) void {
            self.view.setPrev(pid);
        }

        pub fn getPrev(self: *const Self) ?PageIdT {
            return self.view.getPrev();
        }
    };

    return struct {
        pub const Error = ChunkImpl.Error;
        pub const PageId = PageIdT;
        pub const Index = IndexT;
        pub const Additional = PageChainView.PageView.Additional;
        pub const PageView = PageChainView.PageView;
        pub const Chunk = ChunkImpl;
        pub const SlotsDir = SlotsDirType;
    };
}
