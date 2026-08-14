const std = @import("std");
const fullaz = @import("fullaz");
const common = @import("common.zig");

const cloud = common.cloud;
const constants = cloud.constants;
const superblock = cloud.superblock;
const Device = common.Device;
const PageCache = common.PageCache;
const Manager = cloud.storage.Manager(PageCache);

const testing = std.testing;

test "cloud: the storage manager satisfies the paged orthtree contract" {
    comptime fullaz.spatial.orthtree.models.interfaces.requiresPagedStorageManager(
        Manager,
        Manager.NodeId,
    );
}

test "cloud: one size class means the fsm keeps a single root" {
    const policy = cloud.storage.NodeSizePolicy{};

    try testing.expectEqual(@as(usize, 1), policy.count());
    try testing.expectEqual(@as(u16, 0), try policy.getSizeClass(1));
    try testing.expectEqual(@as(u16, 0), try policy.getSizeClass(60_000));
}

const Fixture = struct {
    device: Device,
    cache: PageCache,

    fn init(self: *Fixture) !void {
        self.device = try Device.init(testing.allocator, common.block_size);
        errdefer self.device.deinit();
        self.cache = try PageCache.init(&self.device, testing.allocator, common.frames);
        errdefer self.cache.deinit();

        var handle = try self.cache.create();
        defer handle.deinit();
        std.debug.assert(try handle.pid() == constants.superblock_pid);
        var view = superblock.View(false).init(try handle.dataMut());
        view.format(common.block_size, 1, 4);
    }

    fn deinit(self: *Fixture) void {
        self.cache.deinit();
        self.device.deinit();
    }

    fn readBack(self: *Fixture) !superblock.View(true) {
        // The device holds the flushed bytes; read them, not the cached page.
        try self.cache.flushAll();
        return superblock.View(true).init(self.device.storage.items[0..common.block_size]);
    }
};

test "cloud: the manager writes root, count and fsm root through to the superblock" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var manager = Manager.init(&fixture.cache, .{});
    try manager.setRoot(.{ .page_id = 3, .slot_id = 6 });
    try manager.setEntriesCount(4242);
    try manager.setSizeClassRoot(0, 17);

    const view = try fixture.readBack();
    const root = view.getRoot().?;
    try testing.expectEqual(@as(constants.PageId, 3), root.page_id);
    try testing.expectEqual(@as(u16, 6), root.slot_id);
    try testing.expectEqual(@as(usize, 4242), try view.getEntriesCount());
    try testing.expectEqual(@as(?constants.PageId, 17), try manager.getSizeClassRoot(0));
    try testing.expectEqual(@as(?constants.PageId, 17), view.getFsmClassRoot());
}

test "cloud: the manager reports what it was opened with" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var manager = Manager.init(&fixture.cache, .{
        .root = .{ .page_id = 8, .slot_id = 2 },
        .entries_count = 99,
        .fsm_class_root = 5,
    });

    try testing.expectEqual(@as(constants.PageId, 8), manager.getRoot().?.page_id);
    try testing.expectEqual(@as(u16, 2), manager.getRoot().?.slot_id);
    try testing.expectEqual(@as(usize, 99), try manager.getEntriesCount());
    try testing.expectEqual(@as(?constants.PageId, 5), try manager.getSizeClassRoot(0));
}

// setEntriesCount fires on every insert, so it must not flush: it only dirties
// the cached frame. A flush here would be one device write per point.
test "cloud: writing through does not reach the device on its own" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.cache.flushAll();

    var manager = Manager.init(&fixture.cache, .{});
    try manager.setEntriesCount(7);

    const stale = superblock.View(true).init(fixture.device.storage.items[0..common.block_size]);
    try testing.expectEqual(@as(usize, 0), try stale.getEntriesCount());

    try fixture.cache.flushAll();
    const fresh = superblock.View(true).init(fixture.device.storage.items[0..common.block_size]);
    try testing.expectEqual(@as(usize, 7), try fresh.getEntriesCount());
}

test "cloud: the manager releases every frame it pins" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var manager = Manager.init(&fixture.cache, .{});
    const available_before = fixture.cache.availableFrames();

    try manager.setRoot(.{ .page_id = 1, .slot_id = 0 });
    try manager.setEntriesCount(1);
    try manager.setSizeClassRoot(0, 2);

    try testing.expectEqual(available_before, fixture.cache.availableFrames());
}
