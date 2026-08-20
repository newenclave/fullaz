const std = @import("std");
const fullaz = @import("fullaz");

const SlotHeap = fullaz.page.slot_heap.SlotHeap;
const LeafPageLocationAccessor = fullaz.page.slot_heap.LeafPageLocationAccessor;

test "SlotHeap page: leaf FSM location accessor satisfies the contract" {
    const Accessor = LeafPageLocationAccessor(u32, u16, .little);
    comptime fullaz.storage.fsm.location_accessor.assertAccessor(Accessor);
}

test "SlotHeap page: leaf subheader initializes persistent metadata" {
    const Format = SlotHeap(u32, u16, .little);
    var leaf: Format.LeafSubheader = undefined;
    leaf.formatHeader(24, 0x12345678);

    try std.testing.expect(leaf.parent_pid.isMax());
    try std.testing.expect(leaf.fsm_location.page_id.isMax());
    try std.testing.expect(leaf.fsm_location.slot_id.isMax());
    try std.testing.expectEqual(Format.page_format_version, leaf.format_version.get());
    try std.testing.expectEqual(@as(u16, 24), leaf.key_size.get());
    try std.testing.expectEqual(@as(u32, 0x12345678), leaf.comparator_id.get());
    try std.testing.expectEqual(@as(u8, 0), leaf.reserved);
}

test "SlotHeap page: inode subheader initializes topology and availability" {
    const Format = SlotHeap(u32, u16, .little);
    var inode: Format.InodeSubheader = undefined;
    inode.formatHeader(3, 16, 7);

    try std.testing.expect(inode.parent_pid.isMax());
    try std.testing.expectEqual(@as(u16, 3), inode.level.get());
    try std.testing.expect(inode.available_prev.isMax());
    try std.testing.expect(inode.available_next.isMax());
    try std.testing.expectEqual(Format.page_format_version, inode.format_version.get());
    try std.testing.expectEqual(@as(u16, 16), inode.key_size.get());
    try std.testing.expectEqual(@as(u32, 7), inode.comparator_id.get());
    try std.testing.expectEqual(@as(u8, 0), inode.available_linked);
    try std.testing.expectEqual([_]u8{ 0, 0, 0 }, inode.reserved);
}

test "SlotHeap page: numeric metadata preserves configured endianness" {
    const Little = SlotHeap(u32, u16, .little);
    const Big = SlotHeap(u32, u16, .big);
    var little: Little.LeafSubheader = undefined;
    var big: Big.LeafSubheader = undefined;

    little.formatHeader(0x0102, 0x03040506);
    big.formatHeader(0x0102, 0x03040506);

    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x01 }, &little.key_size.bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02 }, &big.key_size.bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0x06, 0x05, 0x04, 0x03 }, &little.comparator_id.bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x04, 0x05, 0x06 }, &big.comparator_id.bytes);
}

test "SlotHeap page: inode slot prefix stores child and direct leaf winner" {
    const Format = SlotHeap(u32, u16, .little);
    var entry: Format.InodeSlotHeader = undefined;
    entry.child_pid.set(41);
    entry.leaf_top.page_id.set(17);
    entry.leaf_top.slot_id.set(0);

    try std.testing.expectEqual(@as(u32, 41), entry.child_pid.get());
    try std.testing.expectEqual(@as(u32, 17), entry.leaf_top.page_id.get());
    try std.testing.expectEqual(@as(u16, 0), entry.leaf_top.slot_id.get());
    try std.testing.expectEqual(@as(usize, 10), @sizeOf(Format.InodeSlotHeader));
}

test "SlotHeap page: leaf FSM location accessor round trips and clears" {
    const Format = SlotHeap(u32, u16, .little);
    const Accessor = LeafPageLocationAccessor(u32, u16, .little);
    const HeaderView = fullaz.page.header.View(u32, u16, .little, false);

    var page: [256]u8 = undefined;
    var header_view = HeaderView.init(&page);
    header_view.formatPage(23, 5, @sizeOf(Format.LeafSubheader), 0);
    const leaf: *Format.LeafSubheader = @ptrCast(@alignCast(&header_view.subheaderMut()[0]));
    leaf.formatHeader(8, 9);

    try std.testing.expectEqual(@as(?Accessor.Location, null), try Accessor.read(&page));
    try Accessor.write(&page, .{ .page_id = 77, .slot_id = 4 });
    const location = (try Accessor.read(&page)).?;
    try std.testing.expectEqual(@as(u32, 77), location.page_id);
    try std.testing.expectEqual(@as(u16, 4), location.slot_id);

    try Accessor.clear(&page);
    try std.testing.expectEqual(@as(?Accessor.Location, null), try Accessor.read(&page));
}

test "SlotHeap page: leaf FSM location accessor rejects partial null" {
    const Format = SlotHeap(u32, u16, .little);
    const Accessor = LeafPageLocationAccessor(u32, u16, .little);
    const HeaderView = fullaz.page.header.View(u32, u16, .little, false);

    var page: [256]u8 = undefined;
    var header_view = HeaderView.init(&page);
    header_view.formatPage(23, 5, @sizeOf(Format.LeafSubheader), 0);
    const leaf: *Format.LeafSubheader = @ptrCast(@alignCast(&header_view.subheaderMut()[0]));
    leaf.formatHeader(8, 9);
    leaf.fsm_location.page_id.set(1);

    try std.testing.expectError(error.InconsistentLayout, Accessor.read(&page));
}
