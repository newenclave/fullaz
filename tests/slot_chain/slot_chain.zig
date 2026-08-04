const std = @import("std");
const fullaz = @import("fullaz");
const slot_chain = fullaz.storage.slot_chain;

test "SlotChain: create" {
    const View = slot_chain.view.View(u32, u32, .little, false);
    const Header = View.Header;

    std.debug.print("Header size: {d}\n", .{@sizeOf(Header)});

    const hdr: Header = undefined;
    std.debug.print("Header: {any}\n", .{hdr});
}
