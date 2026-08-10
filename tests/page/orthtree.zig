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

test "OrthTree page: packed node slot format initializes references" {
    const Format = Orthtree(u32, u16, i32, 2, .little);
    var node: Format.NodeSlotSubheader = undefined;
    node.formatHeader();

    try std.testing.expect(node.parent.page_id.isMax());
    try std.testing.expect(node.parent.slot_id.isMax());
    try std.testing.expect(node.entries_first.isMax());
    try std.testing.expect(node.entries_last.isMax());
    try std.testing.expectEqual(@as(u32, 0), node.entries_count.get());
    try std.testing.expectEqual(@as(u8, 0), node.level);
    try std.testing.expectEqual(@as(u8, 0), node.flags);
    try std.testing.expectEqual([_]u8{ 0, 0 }, node.reserved);
    inline for (0..Format.children_per_node) |index| {
        try std.testing.expect(node.children[index].page_id.isMax());
        try std.testing.expect(node.children[index].slot_id.isMax());
    }
}

test "OrthTree page: node page header stores layout and slot format" {
    const Format = Orthtree(u32, u16, i32, 2, .little);
    var page: Format.NodePageSubheader = undefined;
    page.formatHeader(0x12345678, @sizeOf(Format.NodeSlotSubheader));

    try std.testing.expect(page.fsm_location.page_id.isMax());
    try std.testing.expect(page.fsm_location.slot_id.isMax());
    try std.testing.expectEqual(@as(u32, 0x12345678), page.layout_id.get());
    try std.testing.expectEqual(@as(u16, @sizeOf(Format.NodeSlotSubheader)), page.slot_size.get());
    try std.testing.expectEqual(Format.node_page_format_version, page.format_version);
    try std.testing.expectEqual(@as(u8, 0), page.reserved);
}

test "OrthTree page: three dimensional f64 slot has expected fixed size" {
    const Format = Orthtree(u32, u16, f64, 3, .little);

    try std.testing.expectEqual(@as(usize, 118), @sizeOf(Format.NodeSlotSubheader));
    try std.testing.expectEqual(@as(usize, 14), @sizeOf(Format.NodePageSubheader));
    const id: Format.NodeId = .{ .page_id = 7, .slot_id = 3 };
    try std.testing.expectEqual(@as(u32, 7), id.page_id);
    try std.testing.expectEqual(@as(u16, 3), id.slot_id);
}
