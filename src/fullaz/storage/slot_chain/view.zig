const std = @import("std");
const page = @import("../../page/page_chain.zig");
const slots = @import("../../slots/variadic.zig");

const headers = @import("../../page/page_chain.zig");
const subheaders = @import("../../page/subheader.zig");

pub fn View(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime Endian: std.builtin.Endian,
    comptime read_only: bool,
) type {
    const SubheadersType = headers.PageChain(PageIdT, Endian);
    const SlotDir = slots.Variadic(IndexT, Endian, read_only);
    const DataType = if (read_only) []const u8 else []u8;

    const NodeImpl = struct {
        pub const SubheaderType = SubheadersType.Subheader;
        pub const SubheaderView = subheaders.View(PageIdT, IndexT, SubheaderType, Endian, read_only);

        const Self = @This();
        pub const Error = error{} || page.PageError;

        page_view: SubheaderView = undefined,

        pub fn init(data: DataType) Self {
            return .{
                .page_view = SubheaderView.init(data),
            };
        }

        pub fn formatPage(self: *Self, kind: u16, page_id: PageIdT, metadata_len: IndexT) void {
            if (read_only) {
                @compileError("Cannot format a read-only page");
            }
            self.page_view.formatPage(kind, page_id, metadata_len);
            var sh = self.subheaderMut();
            sh.back.setMax();
            sh.fwd.setMax();
        }
    };

    return struct {
        pub const Node = NodeImpl;
        pub const SubheaderType = SubheadersType.Subheader;
        pub const SubheaderView = subheaders.View(PageIdT, IndexT, SubheaderType, Endian, read_only);
        pub const SlotDirectory = SlotDir;
    };
}
