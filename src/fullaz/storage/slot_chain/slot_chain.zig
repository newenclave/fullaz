const std = @import("std");
const view = @import("view.zig");
const handle = @import("handle.zig");
const state = @import("state.zig");

pub const scanRefs = @import("scanner.zig").scanRefs;
pub const State = state.State;

pub const View = @import("view.zig").View;
pub const ViewImpl = @import("view.zig").ViewImpl;
pub const Handle = @import("handle.zig").Handle;
pub const HandleImpl = @import("handle.zig").HandleImpl;
pub const Settings = @import("handle.zig").Settings;

pub const ForwardViewImpl = view.ViewForwardImpl;
pub const BidirectionalViewImpl = view.ViewBidirectionalImpl;

pub fn ForwardView(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime Endian: std.builtin.Endian,
    comptime read_only: bool,
) type {
    return ForwardViewImpl(PageIdT, IndexT, void, Endian, read_only);
}

pub fn BidirectionalView(
    comptime PageIdT: type,
    comptime IndexT: type,
    comptime Endian: std.builtin.Endian,
    comptime read_only: bool,
) type {
    return BidirectionalViewImpl(PageIdT, IndexT, void, Endian, read_only);
}

pub const ForwardHandleImpl = handle.HandleForwardImpl;
pub const BidirectionalHandleImpl = handle.HandleBidirectionalImpl;

pub fn ForwardHandle(
    comptime PageCacheT: type,
    comptime StorageManagerT: type,
    comptime SizeT: type,
    comptime TailT: type,
    comptime Endian: std.builtin.Endian,
) type {
    return ForwardHandleImpl(
        PageCacheT,
        StorageManagerT,
        SizeT,
        TailT,
        void,
        void,
        void,
        Endian,
    );
}

pub fn BidirectionalHandle(
    comptime PageCacheT: type,
    comptime StorageManagerT: type,
    comptime SizeT: type,
    comptime TailT: type,
    comptime Endian: std.builtin.Endian,
) type {
    return BidirectionalHandleImpl(
        PageCacheT,
        StorageManagerT,
        SizeT,
        TailT,
        void,
        void,
        void,
        Endian,
    );
}
