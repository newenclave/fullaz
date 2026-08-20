const std = @import("std");
const fullaz = @import("fullaz");
const validation_enabled = fullaz.slot_heap.models.paged.View(
    u32,
    u16,
    .little,
    true,
).full_validation_enabled;

fn expectFullValidationError(expected: anyerror, actual: anytype) !void {
    if (validation_enabled) {
        try std.testing.expectError(expected, actual);
    } else {
        try actual;
    }
}

const MutableView = fullaz.slot_heap.models.paged.View(u32, u16, .little, false);
const ConstView = fullaz.slot_heap.models.paged.View(u32, u16, .little, true);

test "SlotHeap paged view: leaf entries round trip, swap, and remove last" {
    var page: [256]u8 = undefined;
    var leaf = MutableView.Leaf.init(&page);
    try leaf.formatPage(31, 7, 4, 9);
    try leaf.validatePage(7, 31, 4, 9);

    try std.testing.expectEqual(@as(usize, 0), try leaf.append("k003", "short"));
    try std.testing.expectEqual(@as(usize, 1), try leaf.append("k001", "a longer value"));
    try std.testing.expectEqual(@as(usize, 2), try leaf.append("k002", "v"));

    try leaf.swapEntries(0, 1);
    var entry = try leaf.get(0);
    try std.testing.expectEqualSlices(u8, "k001", entry.key);
    try std.testing.expectEqualSlices(u8, "a longer value", entry.value);

    try leaf.removeLast();
    try std.testing.expectEqual(@as(usize, 2), try leaf.entries());

    const reopened = ConstView.Leaf.init(&page);
    try reopened.validatePage(7, 31, 4, 9);
    entry = try reopened.get(1);
    try std.testing.expectEqualSlices(u8, "k003", entry.key);
    try std.testing.expectEqualSlices(u8, "short", entry.value);
}

test "SlotHeap paged view: leaf validates key length and identity" {
    var page: [256]u8 = undefined;
    var leaf = MutableView.Leaf.init(&page);
    try leaf.formatPage(31, 7, 4, 9);

    try std.testing.expectError(error.BadKeyLength, leaf.append("bad", "value"));
    try std.testing.expectError(error.BadData, leaf.validatePage(8, 31, 4, 9));
    try std.testing.expectError(error.BadType, leaf.validatePage(7, 32, 4, 9));
    try std.testing.expectError(error.BadData, leaf.validatePage(7, 31, 8, 9));
    try std.testing.expectError(error.ComparatorMismatch, leaf.validatePage(7, 31, 4, 10));
    try std.testing.expectEqual(.not_enough, try leaf.canAppend(70_000));
    try std.testing.expectEqual(.not_enough, try leaf.canAppend(std.math.maxInt(usize)));
}

test "SlotHeap paged view: leaf compaction preserves heap directory order" {
    var page: [256]u8 = undefined;
    var scratch: [256]u8 = undefined;
    var leaf = MutableView.Leaf.init(&page);
    try leaf.formatPage(31, 7, 4, 9);
    _ = try leaf.append("k003", "first");
    _ = try leaf.append("k001", "discarded");
    _ = try leaf.append("k002", "third-long-value");
    var slots_dir = try leaf.slotsDirMut();
    try slots_dir.free(1);
    try leaf.compactInPlace();
    try leaf.compact(&scratch);

    try std.testing.expectEqualSlices(u8, "k003", (try leaf.get(0)).key);
    try std.testing.expectEqualSlices(u8, "k002", (try leaf.get(2)).key);
}

test "SlotHeap paged view: leaf rejects freed directory holes" {
    var page: [256]u8 = undefined;
    var leaf = MutableView.Leaf.init(&page);
    try leaf.formatPage(31, 7, 4, 9);
    _ = try leaf.append("k001", "one");
    _ = try leaf.append("k002", "two");
    var slots_dir = try leaf.slotsDirMut();
    try slots_dir.free(0);

    try expectFullValidationError(error.BadData, leaf.validatePage(7, 31, 4, 9));
}

test "SlotHeap paged view: leaf rejects corrupted variadic bounds" {
    var page: [256]u8 = undefined;
    var leaf = MutableView.Leaf.init(&page);
    try leaf.formatPage(31, 7, 4, 9);
    var slots_dir = try leaf.slotsDirMut();
    slots_dir.headerMut().entry_count.set(std.math.maxInt(u16));

    try std.testing.expectError(
        error.InconsistentLayout,
        leaf.validatePage(7, 31, 4, 9),
    );
}

test "SlotHeap paged view: leaf rejects invalid entry with forged length" {
    var page: [256]u8 = undefined;
    var leaf = MutableView.Leaf.init(&page);
    try leaf.formatPage(31, 7, 4, 9);
    _ = try leaf.append("k001", "value");
    var slots_dir = try leaf.slotsDirMut();
    try slots_dir.free(0);
    slots_dir.entriesMut()[0].length.set(4);

    try expectFullValidationError(
        error.InconsistentLayout,
        leaf.validatePage(7, 31, 4, 9),
    );
}

test "SlotHeap paged view: leaf rejects overlapping payloads" {
    var page: [256]u8 = undefined;
    var leaf = MutableView.Leaf.init(&page);
    try leaf.formatPage(31, 7, 4, 9);
    _ = try leaf.append("k001", "first");
    _ = try leaf.append("k002", "second");
    var slots_dir = try leaf.slotsDirMut();
    slots_dir.entriesMut()[1].offset = slots_dir.entries()[0].offset;

    try expectFullValidationError(
        error.InconsistentLayout,
        leaf.validatePage(7, 31, 4, 9),
    );
}

test "SlotHeap paged view: leaf rejects corrupted free-list head" {
    var page: [256]u8 = undefined;
    var leaf = MutableView.Leaf.init(&page);
    try leaf.formatPage(31, 7, 4, 9);
    _ = try leaf.append("k001", "first-value");
    _ = try leaf.append("k002", "second-value");
    var slots_dir = try leaf.slotsDirMut();
    slots_dir.headerMut().freed.set(slots_dir.entries()[0].offset.get());

    try expectFullValidationError(
        error.InconsistentLayout,
        leaf.validatePage(7, 31, 4, 9),
    );
}

test "SlotHeap paged view: structural free-list traversal rejects invalid links" {
    var page: [256]u8 = undefined;
    var leaf = MutableView.Leaf.init(&page);
    try leaf.formatPage(31, 7, 4, 9);
    _ = try leaf.append("k001", "first-value");
    _ = try leaf.append("k002", "second-value");
    var slots_dir = try leaf.slotsDirMut();
    try slots_dir.free(0);
    try slots_dir.free(1);

    const head: usize = @intCast(slots_dir.header().freed.get());
    std.mem.writeInt(u16, slots_dir.body[head + 2 ..][0..2], 1, .little);

    if (validation_enabled) {
        try std.testing.expectError(
            error.InconsistentLayout,
            leaf.validatePage(7, 31, 4, 9),
        );
    } else {
        try leaf.validatePage(7, 31, 4, 9);
    }
    try std.testing.expectError(error.InconsistentLayout, leaf.canAppend(200));
}

test "SlotHeap paged view: mutation rejects an invalid persisted slot offset" {
    var page: [256]u8 = undefined;
    var leaf = MutableView.Leaf.init(&page);
    try leaf.formatPage(31, 7, 4, 9);
    _ = try leaf.append("k001", "value");
    var slots_dir = try leaf.slotsDirMut();
    slots_dir.entriesMut()[0].offset.set(2);

    try std.testing.expectError(error.InconsistentLayout, leaf.removeLast());
}

test "SlotHeap paged view: inode entries use a dense fixed-slot heap" {
    var page: [256]u8 = undefined;
    var inode = MutableView.Inode.init(&page);
    try inode.formatPage(32, 11, 2, 4, 9);
    try std.testing.expect((try inode.capacity()) >= 2);

    _ = try inode.append("k003", 20, .{ .page_id = 100, .slot_id = 0 });
    _ = try inode.append("k001", 21, .{ .page_id = 101, .slot_id = 0 });
    _ = try inode.append("k002", 22, .{ .page_id = 102, .slot_id = 0 });
    try inode.swapEntries(0, 1);

    var entry = try inode.get(0);
    try std.testing.expectEqualSlices(u8, "k001", entry.key);
    try std.testing.expectEqual(@as(u32, 21), entry.child_pid);
    try std.testing.expectEqual(@as(u32, 101), entry.leaf_top.page_id);
    try std.testing.expectEqual(@as(?usize, 2), try inode.findChild(22));

    try inode.setEntry(2, "k000", 22, .{ .page_id = 103, .slot_id = 0 });
    entry = try inode.get(2);
    try std.testing.expectEqualSlices(u8, "k000", entry.key);
    try std.testing.expectEqual(@as(u32, 103), entry.leaf_top.page_id);

    try inode.removeLast();
    try std.testing.expectEqual(@as(usize, 2), try inode.entries());
    try inode.validatePage(11, 32, 4, 9);
}

test "SlotHeap paged view: inode parent and availability metadata round trip" {
    var page: [256]u8 = undefined;
    var inode = MutableView.Inode.init(&page);
    try inode.formatPage(32, 11, 3, 4, 9);

    try inode.setParent(44);
    try inode.setAvailablePrev(8);
    try inode.setAvailableNext(9);
    inode.setAvailableLinked(true);

    try std.testing.expectEqual(@as(?u32, 44), inode.getParent());
    try std.testing.expectEqual(@as(usize, 3), inode.getLevel());
    try std.testing.expectEqual(@as(?u32, 8), inode.getAvailablePrev());
    try std.testing.expectEqual(@as(?u32, 9), inode.getAvailableNext());
    try std.testing.expect(inode.isAvailableLinked());
    try inode.validatePage(11, 32, 4, 9);

    try inode.setAvailablePrev(null);
    try inode.setAvailableNext(null);
    inode.setAvailableLinked(false);
    try inode.validatePage(11, 32, 4, 9);
}

test "SlotHeap paged view: inode validation rejects sparse occupancy" {
    var page: [256]u8 = undefined;
    var inode = MutableView.Inode.init(&page);
    try inode.formatPage(32, 11, 1, 4, 9);
    _ = try inode.append("k001", 20, .{ .page_id = 100, .slot_id = 0 });
    _ = try inode.append("k002", 21, .{ .page_id = 101, .slot_id = 0 });
    var slots_dir = try inode.slotsDirMut();
    try slots_dir.free(0);

    try expectFullValidationError(error.BadData, inode.validatePage(11, 32, 4, 9));
}

test "SlotHeap paged view: inode rejects corrupted fixed-slot bounds" {
    var page: [256]u8 = undefined;
    var inode = MutableView.Inode.init(&page);
    try inode.formatPage(32, 11, 1, 4, 9);
    var slots_dir = try inode.slotsDirMut();
    const fixed_header = @constCast(slots_dir.header());
    fixed_header.capacity.set(std.math.maxInt(u16));

    try std.testing.expectError(error.InconsistentLayout, inode.validatePage(11, 32, 4, 9));
}

test "SlotHeap paged view: inode rejects nonzero fixed bitmap padding" {
    var page: [256]u8 = undefined;
    var inode = MutableView.Inode.init(&page);
    try inode.formatPage(32, 11, 1, 4, 9);
    const slots_dir = try inode.slotsDir();
    const slot_capacity = try slots_dir.capacity();
    try std.testing.expect(slot_capacity % 16 != 0);

    const data_offset = inode.page_view.allHeadersSize();
    const fixed_header_size = std.mem.asBytes(slots_dir.header()).len;
    std.mem.writeInt(u16, page[data_offset + fixed_header_size ..][0..2], 0x8000, .little);

    try std.testing.expectError(error.InconsistentLayout, inode.validatePage(11, 32, 4, 9));
}

test "SlotHeap paged view: inode validation checks persisted settings" {
    var page: [256]u8 = undefined;
    var inode = MutableView.Inode.init(&page);
    try inode.formatPage(32, 11, 1, 4, 9);

    try std.testing.expectError(error.BadData, inode.validatePage(12, 32, 4, 9));
    try std.testing.expectError(error.BadType, inode.validatePage(11, 31, 4, 9));
    try std.testing.expectError(error.BadData, inode.validatePage(11, 32, 8, 9));
    try std.testing.expectError(error.ComparatorMismatch, inode.validatePage(11, 32, 4, 10));
}

test "SlotHeap paged view: inode append validates complete entry before allocation" {
    var page: [256]u8 = undefined;
    var inode = MutableView.Inode.init(&page);
    try inode.formatPage(32, 11, 1, 4, 9);

    try std.testing.expectError(
        error.BadKeyLength,
        inode.append("bad", 20, .{ .page_id = 100, .slot_id = 0 }),
    );
    try std.testing.expectError(
        error.BadData,
        inode.append("k001", 20, .{ .page_id = std.math.maxInt(u32), .slot_id = 0 }),
    );
    try std.testing.expectEqual(@as(usize, 0), try inode.entries());
}

test "SlotHeap paged view: inode setEntry accepts its currently borrowed key" {
    var page: [256]u8 = undefined;
    var inode = MutableView.Inode.init(&page);
    try inode.formatPage(32, 11, 1, 4, 9);
    _ = try inode.append("k001", 20, .{ .page_id = 100, .slot_id = 0 });
    const borrowed_key = (try inode.get(0)).key;

    try inode.setEntry(0, borrowed_key, 21, .{ .page_id = 101, .slot_id = 0 });

    const entry = try inode.get(0);
    try std.testing.expectEqualSlices(u8, "k001", entry.key);
    try std.testing.expectEqual(@as(u32, 21), entry.child_pid);
    try std.testing.expectEqual(@as(u32, 101), entry.leaf_top.page_id);
}

test "SlotHeap paged view: inode format rejects oversized key before mutation" {
    var page = [_]u8{0xaa} ** 256;
    var inode = MutableView.Inode.init(&page);

    try std.testing.expectError(
        error.BadKeyLength,
        inode.formatPage(32, 11, 1, std.math.maxInt(u16), 9),
    );
    try std.testing.expectEqualSlices(u8, &([_]u8{0xaa} ** 16), page[0..16]);
}

test "SlotHeap paged view: optional page IDs reject the null sentinel" {
    var page: [256]u8 = undefined;
    var inode = MutableView.Inode.init(&page);
    try inode.formatPage(32, 11, 1, 4, 9);

    try std.testing.expectError(error.BadData, inode.setParent(std.math.maxInt(u32)));
    try std.testing.expectError(error.BadData, inode.setAvailablePrev(std.math.maxInt(u32)));
    try std.testing.expectError(error.BadData, inode.setAvailableNext(std.math.maxInt(u32)));
    try std.testing.expectEqual(@as(?u32, null), inode.getParent());
}
