const std = @import("std");
const fullaz = @import("fullaz");

const MutableView = fullaz.spatial.rtree.models.paged.View(u32, u16, i64, 2, .little, false);
const ConstView = fullaz.spatial.rtree.models.paged.View(u32, u16, i64, 2, .little, true);
const Key = MutableView.KeyType;
const Page = fullaz.page.rtree.Rtree(u32, u16, i64, 2, .little);

fn box(x0: i64, y0: i64, x1: i64, y1: i64) Key {
    return Key.initWith(.{ x0, y0 }, .{ x1, y1 });
}

fn expectFullValidationError(expected: anyerror, actual: anytype) !void {
    if (MutableView.full_validation_enabled) {
        try std.testing.expectError(expected, actual);
    } else {
        try actual;
    }
}

test "RTree paged view: leaf validates header, bounds, and entry limits" {
    var page: [512]u8 = undefined;
    var leaf = MutableView.LeafSubheaderView.init(&page);
    try leaf.formatPage(31, 7, 0);
    try leaf.append(box(0, 0, 1, 1), "value");
    try leaf.validatePage(7, 31, 4, 5);

    try std.testing.expectError(error.BadData, leaf.validatePage(8, 31, 4, 5));
    try std.testing.expectError(error.BadType, leaf.validatePage(7, 32, 4, 5));

    var slots = try leaf.slotsDirMut();
    slots.entriesMut()[0].length.set(@sizeOf(Page.LeafSlotHeader) - 1);
    try std.testing.expectError(error.BadData, leaf.validatePage(7, 31, 4, 5));

    slots.entriesMut()[0].length.set(@sizeOf(Page.LeafSlotHeader) + 4);
    try std.testing.expectError(error.BadData, leaf.validatePage(7, 31, 4, 3));
}

test "RTree paged view: inode validates level, child IDs, and slot sizes" {
    var page: [512]u8 = undefined;
    var inode = MutableView.InodeSubheaderView.init(&page);
    try inode.formatPage(32, 8, 0);
    try inode.setLevel(1);
    try inode.append(box(0, 0, 1, 1), 9);
    try inode.validatePage(8, 32, 4);

    try std.testing.expectError(error.BadData, inode.setLevel(0));
    try std.testing.expectError(error.BadData, inode.setLevel(64));
    try std.testing.expectError(error.BadData, inode.append(box(0, 0, 1, 1), std.math.maxInt(u32)));

    inode.subheaderMut().level.set(64);
    try std.testing.expectError(error.BadData, inode.validatePage(8, 32, 4));
    inode.subheaderMut().level.set(1);

    var slots = try inode.slotsDirMut();
    slots.entriesMut()[0].length.set(@sizeOf(Page.InodeSlotHeader) - 1);
    try std.testing.expectError(error.BadData, inode.validatePage(8, 32, 4));
}

test "RTree paged view: full validation rejects overlapping payloads" {
    var page: [512]u8 = undefined;
    var leaf = MutableView.LeafSubheaderView.init(&page);
    try leaf.formatPage(31, 7, 0);
    try leaf.append(box(0, 0, 1, 1), "first");
    try leaf.append(box(2, 2, 3, 3), "other");

    var slots = try leaf.slotsDirMut();
    slots.entriesMut()[1].offset = slots.entries()[0].offset;
    try expectFullValidationError(error.InconsistentLayout, leaf.validatePage(7, 31, 4, 32));

    const reopened = ConstView.LeafSubheaderView.init(&page);
    try expectFullValidationError(error.InconsistentLayout, reopened.validatePage(7, 31, 4, 32));
}
