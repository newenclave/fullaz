const std = @import("std");
const linked_sh = @import("fullaz").page.linked_subheader;

test "LinkedSubheader: format page" {
    const LLView = linked_sh.View(u32, u16, u32, std.builtin.Endian.little, false);

    var buf = [_]u8{0} ** 1024;
    var view = LLView.init(&buf);
    view.formatPage(1, 42, 0);
    view.setFwd(100);
    view.setBack(200);

    try std.testing.expectEqual(100, view.getFwd() orelse unreachable);
    try std.testing.expectEqual(200, view.getBack() orelse unreachable);

    _ = view.subheaderMut();
}
