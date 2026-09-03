const view = @import("view.zig");
const handle = @import("handle.zig");
const state = @import("state.zig");

pub const scanRefs = @import("scanner.zig").scanRefs;
pub const State = state.State;

pub const View = view.View;
pub const ViewImpl = view.ViewImpl;
pub const ForwardViewImpl = view.ViewForwardImpl;
pub const BidirectionalViewImpl = view.ViewBidirectionalImpl;
pub const Handle = handle.Handle;
pub const HandleImpl = handle.HandleImpl;
pub const ForwardHandleImpl = handle.HandleForwardImpl;
pub const BidirectionalHandleImpl = handle.HandleBidirectionalImpl;

pub fn ForwardView(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime Endian: @import("std").builtin.Endian,
    comptime read_only: bool,
) type {
    return ForwardViewImpl(PageIdT, IndexT, void, Endian, read_only);
}

pub fn BidirectionalView(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime Endian: @import("std").builtin.Endian,
    comptime read_only: bool,
) type {
    return BidirectionalViewImpl(PageIdT, IndexT, void, Endian, read_only);
}

pub fn ForwardHandle(
    comptime PageCacheT: type,
    comptime StorageManagerT: type,
    comptime TailT: type,
    comptime SubheaderT: type,
    comptime Endian: @import("std").builtin.Endian,
) type {
    return ForwardHandleImpl(PageCacheT, StorageManagerT, TailT, void, SubheaderT, Endian);
}

pub fn BidirectionalHandle(
    comptime PageCacheT: type,
    comptime StorageManagerT: type,
    comptime TailT: type,
    comptime SubheaderT: type,
    comptime Endian: @import("std").builtin.Endian,
) type {
    return BidirectionalHandleImpl(PageCacheT, StorageManagerT, TailT, void, SubheaderT, Endian);
}

pub const Settings = struct {
    chunk_page_kind: u16 = 0x41,
};
