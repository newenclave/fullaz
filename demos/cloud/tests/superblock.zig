const std = @import("std");
const common = @import("common.zig");

const cloud = common.cloud;
const superblock = cloud.superblock;
const constants = cloud.constants;

const testing = std.testing;

const Mut = superblock.View(false);
const Ro = superblock.View(true);

fn freshPage(page: []u8) Mut {
    var view = Mut.init(page);
    view.format(common.block_size, 0xABCDEF, 12);
    return view;
}

test "cloud: superblock header is byte aligned and fits a page" {
    try testing.expectEqual(@as(usize, 1), @alignOf(superblock.Header));
    try testing.expect(@sizeOf(superblock.Header) <= common.block_size);
}

test "cloud: a formatted superblock validates and starts empty" {
    var page: [common.block_size]u8 = undefined;
    var view = freshPage(&page);

    try view.validate(common.block_size);
    try testing.expectEqual(@as(?superblock.NodeId, null), view.getRoot());
    try testing.expectEqual(@as(usize, 0), try view.getEntriesCount());
    try testing.expectEqual(@as(?constants.PageId, null), view.getFsmClassRoot());
    try testing.expectEqual(@as(?constants.PageId, null), view.getFreePageRoot());
    try testing.expectEqual(@as(usize, 0), view.getFreePageCount());
    try testing.expectEqual(@as(usize, 0), view.getReusedPageCount());
    try testing.expectEqual(@as(u64, 0xABCDEF), view.getSeed());
    try testing.expectEqual(@as(u32, 0), view.getNextPointId());
    try testing.expectEqual(@as(u16, 12), view.getClusterCount());
}

// The orthtree root is a {page_id, slot_id} pair and nodes share pages, so the
// root is very often not slot 0. Dropping the slot would silently lose the tree.
test "cloud: superblock round-trips a root node id including its slot" {
    var page: [common.block_size]u8 = undefined;
    var view = freshPage(&page);

    view.setRoot(.{ .page_id = 9, .slot_id = 5 });
    const restored = Ro.init(&page).getRoot().?;

    try testing.expectEqual(@as(constants.PageId, 9), restored.page_id);
    try testing.expectEqual(@as(u16, 5), restored.slot_id);

    view.setRoot(null);
    try testing.expectEqual(@as(?superblock.NodeId, null), Ro.init(&page).getRoot());
}

test "cloud: superblock round-trips the counters and the fsm root" {
    var page: [common.block_size]u8 = undefined;
    var view = freshPage(&page);

    view.setEntriesCount(200_000);
    view.setNextPointId(200_000);
    view.setFsmClassRoot(41);
    view.setFreePageRoot(42);
    view.setFreePageCount(17);
    view.setReusedPageCount(9);

    const ro = Ro.init(&page);
    try testing.expectEqual(@as(usize, 200_000), try ro.getEntriesCount());
    try testing.expectEqual(@as(u32, 200_000), ro.getNextPointId());
    try testing.expectEqual(@as(?constants.PageId, 41), ro.getFsmClassRoot());
    try testing.expectEqual(@as(?constants.PageId, 42), ro.getFreePageRoot());
    try testing.expectEqual(@as(usize, 17), ro.getFreePageCount());
    try testing.expectEqual(@as(usize, 9), ro.getReusedPageCount());

    view.setFsmClassRoot(null);
    try testing.expectEqual(@as(?constants.PageId, null), Ro.init(&page).getFsmClassRoot());
}

test "cloud: superblock round-trips the viewer state" {
    var page: [common.block_size]u8 = undefined;
    var view = freshPage(&page);

    view.setDetailFraction(0.0625);
    view.setCamera(.{
        .yaw = 0.75,
        .pitch = -0.5,
        .distance = 1234.5,
        .target = .{ 1, 2, 3 },
    });

    const ro = Ro.init(&page);
    const camera = ro.getCamera();
    try testing.expectEqual(@as(f64, 0.0625), ro.getDetailFraction());
    try testing.expectEqual(@as(f64, 0.75), camera.yaw);
    try testing.expectEqual(@as(f64, -0.5), camera.pitch);
    try testing.expectEqual(@as(f64, 1234.5), camera.distance);
    try testing.expectEqual([3]f64{ 1, 2, 3 }, camera.target);
}

test "cloud: superblock validation rejects a bad magic" {
    var page: [common.block_size]u8 = undefined;
    var view = freshPage(&page);

    view.headerMut().magic.set(constants.magic + 1);
    try testing.expectError(superblock.Error.BadMagic, Ro.init(&page).validate(common.block_size));
}

test "cloud: superblock validation rejects a bad version" {
    var page: [common.block_size]u8 = undefined;
    var view = freshPage(&page);

    view.headerMut().version.set(constants.version + 1);
    try testing.expectError(superblock.Error.BadVersion, Ro.init(&page).validate(common.block_size));
}

test "cloud: superblock validation rejects the v1 image format" {
    var page: [common.block_size]u8 = undefined;
    var view = freshPage(&page);
    view.headerMut().version.set(1);

    try testing.expectError(superblock.Error.BadVersion, Ro.init(&page).validate(common.block_size));
}

test "cloud: superblock validation rejects a mismatched block size" {
    var page: [common.block_size]u8 = undefined;
    _ = freshPage(&page);

    try testing.expectError(
        superblock.Error.BadBlockSize,
        Ro.init(&page).validate(common.block_size * 2),
    );
}

test "cloud: an entry count that overflows usize is reported, not truncated" {
    if (@sizeOf(usize) >= 8) return error.SkipZigTest;

    var page: [common.block_size]u8 = undefined;
    var view = freshPage(&page);
    view.headerMut().entries_count.set(std.math.maxInt(u64));

    try testing.expectError(superblock.Error.BadImage, Ro.init(&page).getEntriesCount());
}
