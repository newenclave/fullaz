const view = @import("view.zig");
const handle = @import("handle.zig");

pub const View = view.View;
pub const ViewImpl = view.ViewImpl;
pub const Handle = handle.Handle;
pub const HandleImpl = handle.HandleImpl;

pub const Settings = struct {
    chunk_page_kind: u16 = 0x41,
};
