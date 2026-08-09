const std = @import("std");
const Orthtree = @import("fullaz").page.orthtree.Orthtree;

test "OrthTree page: node subheader format initializes links and children" {
    const Format = Orthtree(u32, u16, i32, 2, .little);
    var node: Format.NodeSubheader = undefined;
    node.formatHeader();

    try std.testing.expect(node.parent.isMax());
    try std.testing.expect(node.entries_first.isMax());
    try std.testing.expect(node.entries_last.isMax());
    try std.testing.expectEqual(@as(u32, 0), node.entries_count.get());
    try std.testing.expectEqual(@as(u8, 0), node.level);
    try std.testing.expectEqual(@as(u8, 0), node.flags);
    try std.testing.expectEqual([_]u8{ 0, 0 }, node.reserved);
    inline for (0..Format.children_per_node) |index| {
        try std.testing.expect(node.children[index].isMax());
    }
}

test "OrthTree page: numeric fields preserve configured endianness" {
    const Little = Orthtree(u32, u16, i32, 2, .little);
    const Big = Orthtree(u32, u16, i32, 2, .big);
    var little: Little.Mbr = undefined;
    var big: Big.Mbr = undefined;

    little.low[0].set(0x01020304);
    big.low[0].set(0x01020304);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x04, 0x03, 0x02, 0x01 }, &little.low[0].bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03, 0x04 }, &big.low[0].bytes);
}

test "OrthTree page: float bounding boxes round trip" {
    const Format = Orthtree(u32, u16, f32, 2, .little);
    var bounds: Format.Mbr = undefined;

    bounds.low[0].set(-1.25);
    bounds.low[1].set(2.5);
    bounds.high[0].set(3.75);
    bounds.high[1].set(4.0);

    try std.testing.expectEqual(@as(f32, -1.25), bounds.low[0].get());
    try std.testing.expectEqual(@as(f32, 2.5), bounds.low[1].get());
    try std.testing.expectEqual(@as(f32, 3.75), bounds.high[0].get());
    try std.testing.expectEqual(@as(f32, 4.0), bounds.high[1].get());
}
