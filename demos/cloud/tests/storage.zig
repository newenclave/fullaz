const std = @import("std");
const fullaz = @import("fullaz");
const common = @import("common.zig");

const cloud = common.cloud;
const constants = cloud.constants;
const superblock = cloud.superblock;
const Device = common.Device;
const PageCache = common.PageCache;
const Manager = cloud.storage.Manager(PageCache);
const TreeManager = cloud.storage.TreeManager(PageCache);
const FsmManager = cloud.storage.FsmManager(PageCache);

const testing = std.testing;
const FsmState = fullaz.storage.fsm.models.paged.slab.State(
    constants.PageId,
    cloud.storage.NodeSizePolicy,
    constants.endian,
);
const TreeState = Manager.TreeState;
const TreeStateView = fullaz.core.storage_manager.StateAccessor(
    TreeManager.StateLeaseType,
    TreeState,
);
const FsmStateView = fullaz.core.storage_manager.StateAccessor(
    FsmManager.StateLeaseType,
    FsmState,
);

fn fsmRoot(manager: *FsmManager) !?constants.PageId {
    var lease = try manager.state();
    defer lease.deinit();
    const root = (try FsmStateView.view(&lease)).classes[0].first;
    return if (root.isMax()) null else root.get();
}

fn setFsmRoot(manager: *FsmManager, page_id: ?constants.PageId) !void {
    var lease = try manager.state();
    defer lease.deinit();
    const root = &(try FsmStateView.viewMut(&lease)).classes[0].first;
    root.set(page_id orelse std.math.maxInt(constants.PageId));
    lease.finish();
}

fn treeRoot(manager: *TreeManager) !?superblock.NodeId {
    var lease = try manager.state();
    defer lease.deinit();
    const state = try TreeStateView.view(&lease);
    if (state.root_page.isMax()) {
        return null;
    }
    return .{
        .page_id = state.root_page.get(),
        .slot_id = state.root_slot.get(),
    };
}

fn setTreeRoot(manager: *TreeManager, root: ?superblock.NodeId) !void {
    var lease = try manager.state();
    defer lease.deinit();
    const state = try TreeStateView.viewMut(&lease);
    if (root) |node_id| {
        state.root_page.set(node_id.page_id);
        state.root_slot.set(node_id.slot_id);
    } else {
        state.root_page.setMax();
        state.root_slot.set(0);
    }
    lease.finish();
}

fn entriesCount(manager: *TreeManager) !usize {
    var lease = try manager.state();
    defer lease.deinit();
    return @intCast((try TreeStateView.view(&lease)).entries_count.get());
}

fn setEntriesCount(manager: *TreeManager, count: usize) !void {
    var lease = try manager.state();
    defer lease.deinit();
    (try TreeStateView.viewMut(&lease)).entries_count.set(@intCast(count));
    lease.finish();
}

test "cloud: the storage manager satisfies the paged orthtree contract" {
    comptime fullaz.spatial.orthtree.models.interfaces.requiresPagedStorageManager(
        TreeManager,
        constants.PageId,
    );
}

test "cloud: one size class means the fsm keeps a single root" {
    const policy = cloud.storage.NodeSizePolicy{};

    try testing.expectEqual(@as(usize, 1), policy.count());
    try testing.expectEqual(@as(u16, 0), policy.getSizeClass(1));
    try testing.expectEqual(@as(u16, 0), policy.getSizeClass(60_000));
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

    var manager = Manager.init(&fixture.cache);
    var tree_manager = TreeManager.init(&manager);
    var fsm_manager = FsmManager.init(&manager);
    try setTreeRoot(&tree_manager, .{ .page_id = 3, .slot_id = 6 });
    try setEntriesCount(&tree_manager, 4242);
    try setFsmRoot(&fsm_manager, 17);

    const view = try fixture.readBack();
    const root = view.getRoot().?;
    try testing.expectEqual(@as(constants.PageId, 3), root.page_id);
    try testing.expectEqual(@as(u16, 6), root.slot_id);
    try testing.expectEqual(@as(usize, 4242), try view.getEntriesCount());
    try testing.expectEqual(@as(?constants.PageId, 17), try fsmRoot(&fsm_manager));
    try testing.expectEqual(@as(?constants.PageId, 17), view.getFsmClassRoot());
}

test "cloud: projected managers read existing superblock state" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    {
        var handle = try fixture.cache.fetch(constants.superblock_pid);
        defer handle.deinit();
        var view = superblock.View(false).init(try handle.dataMut());
        view.setRoot(.{ .page_id = 8, .slot_id = 2 });
        view.setEntriesCount(99);
        view.setFsmClassRoot(5);
    }
    var manager = Manager.init(&fixture.cache);
    var tree_manager = TreeManager.init(&manager);
    var fsm_manager = FsmManager.init(&manager);

    try testing.expectEqual(@as(constants.PageId, 8), (try treeRoot(&tree_manager)).?.page_id);
    try testing.expectEqual(@as(u16, 2), (try treeRoot(&tree_manager)).?.slot_id);
    try testing.expectEqual(@as(usize, 99), try entriesCount(&tree_manager));
    try testing.expectEqual(@as(?constants.PageId, 5), try fsmRoot(&fsm_manager));
}

// setEntriesCount fires on every insert, so it must not flush: it only dirties
// the cached frame. A flush here would be one device write per point.
test "cloud: writing through does not reach the device on its own" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.cache.flushAll();

    var manager = Manager.init(&fixture.cache);
    var tree_manager = TreeManager.init(&manager);
    try setEntriesCount(&tree_manager, 7);

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

    var manager = Manager.init(&fixture.cache);
    var tree_manager = TreeManager.init(&manager);
    var fsm_manager = FsmManager.init(&manager);
    const available_before = fixture.cache.availableFrames();

    try setTreeRoot(&tree_manager, .{ .page_id = 1, .slot_id = 0 });
    try setEntriesCount(&tree_manager, 1);
    try setFsmRoot(&fsm_manager, 2);

    try testing.expectEqual(available_before, fixture.cache.availableFrames());
}
