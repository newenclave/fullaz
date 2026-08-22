const std = @import("std");
const fullaz = @import("fullaz");

const MutableView = fullaz.bpt.models.paged.View(u32, u16, .little, false);
const ConstView = fullaz.bpt.models.paged.View(u32, u16, .little, true);
const Page = fullaz.page.bpt.Bpt(u32, u16, .little);

fn expectFullValidationError(expected: anyerror, actual: anytype) !void {
    if (MutableView.full_validation_enabled) {
        try std.testing.expectError(expected, actual);
    } else {
        try actual;
    }
}

test "BPT paged view: leaf validates header and configured bounds" {
    var page: [512]u8 = undefined;
    var leaf = MutableView.LeafSubheaderView.init(&page);
    try leaf.formatPage(31, 7, 0);
    try leaf.insert(0, "key", "value");
    try leaf.validatePage(7, 31, 3, 5);

    try std.testing.expectError(error.BadData, leaf.validatePage(8, 31, 3, 5));
    try std.testing.expectError(error.BadType, leaf.validatePage(7, 32, 3, 5));
    try std.testing.expectError(error.BadData, leaf.validatePage(7, 31, 2, 5));
    try std.testing.expectError(error.BadData, leaf.validatePage(7, 31, 3, 4));

    var slots = try leaf.slotsDirMut();
    slots.entriesMut()[0].length.set(@sizeOf(Page.LeafSlotHeader) - 1);
    try std.testing.expectError(error.BadData, leaf.validatePage(7, 31, 3, 5));
    try std.testing.expectError(error.BadData, leaf.get(0));
}

test "BPT paged view: inode validates children and rightmost child" {
    var page: [512]u8 = undefined;
    var inode = MutableView.InodeSubheaderView.init(&page);
    try inode.formatPage(32, 8, 0);
    try inode.insert(0, "key", 9);
    try std.testing.expectError(error.BadData, inode.validatePage(8, 32, 3));

    inode.subheaderMut().rightmost_child.set(10);
    try inode.validatePage(8, 32, 3);
    try std.testing.expectError(error.BadData, inode.insert(1, "other", std.math.maxInt(u32)));
    try std.testing.expectError(error.BadData, inode.updateChild(0, std.math.maxInt(u32)));

    var slots = try inode.slotsDirMut();
    slots.entriesMut()[0].length.set(@sizeOf(Page.InodeSlotHeader) - 1);
    try std.testing.expectError(error.BadData, inode.validatePage(8, 32, 3));
    try std.testing.expectError(error.BadData, inode.get(0));
}

test "BPT paged view: full validation rejects overlapping payloads" {
    var page: [512]u8 = undefined;
    var leaf = MutableView.LeafSubheaderView.init(&page);
    try leaf.formatPage(31, 7, 0);
    try leaf.insert(0, "one", "first");
    try leaf.insert(1, "two", "other");

    var slots = try leaf.slotsDirMut();
    slots.entriesMut()[1].offset = slots.entries()[0].offset;
    try expectFullValidationError(error.InconsistentLayout, leaf.validatePage(7, 31, 32, 32));

    const reopened = ConstView.LeafSubheaderView.init(&page);
    try expectFullValidationError(error.InconsistentLayout, reopened.validatePage(7, 31, 32, 32));
}
