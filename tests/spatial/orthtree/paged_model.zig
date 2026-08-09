const std = @import("std");
const fullaz = @import("fullaz");

const Device = fullaz.device.MemoryBlock(u32);
const Cache = fullaz.storage.page_cache.PageCache(Device);
const TreeImpl = fullaz.spatial.orthtree.tree.TreeImpl;

const StorageManager = struct {
    pub const PageId = u32;
    pub const Error = error{};

    root: ?PageId = null,
    entries_count: usize = 0,

    pub fn getRoot(self: *const @This()) ?PageId {
        return self.root;
    }

    pub fn setRoot(self: *@This(), root: ?PageId) Error!void {
        self.root = root;
    }

    pub fn destroyPage(_: *@This(), _: PageId) Error!void {}

    pub fn getEntriesCount(self: *const @This()) Error!usize {
        return self.entries_count;
    }

    pub fn setEntriesCount(self: *@This(), count: usize) Error!void {
        self.entries_count = count;
    }
};

test "OrthTree paged model: structural nodes persist through accessor loads" {
    const Model = fullaz.spatial.orthtree.models.paged.PagedModel(Cache, StorageManager, i32, 2, .little);
    const Box = Model.Box;

    var device = try Device.init(std.testing.allocator, 1024);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 8);
    defer cache.deinit();
    var storage_manager = StorageManager{};
    var model = try Model.init(&cache, &storage_manager, .{
        .max_leaf_entries = 4,
        .max_value_size = 64,
        .node_page_kind = 0x71,
        .entry_page_kind = 0x72,
    });
    defer model.deinit();

    const accessor = model.getAccessor();
    var root = try accessor.createNode(Box.create(.{ 0, 0 }, .{ 10, 10 }));
    defer accessor.deinitNode(&root);
    const root_id = root.id();
    try accessor.setRoot(root_id);

    var child = try accessor.createNode(Box.create(.{ 0, 0 }, .{ 5, 5 }));
    defer accessor.deinitNode(&child);
    try child.setParent(root_id);
    try child.setLevel(1);
    try root.beforeSplit();
    try root.setChild(0, child.id());

    try model.incrementEntriesCount();
    try model.incrementEntriesCount();
    try std.testing.expectEqual(@as(usize, 2), try model.getEntriesCount());
    try model.decrementEntriesCount();
    try std.testing.expectEqual(@as(usize, 1), try model.getEntriesCount());

    var loaded_root = try accessor.loadNode(root_id);
    defer accessor.deinitNode(&loaded_root);
    try std.testing.expect(!loaded_root.isLeaf());
    try std.testing.expectEqual(@as(?u32, child.id()), loaded_root.getChild(0));
    try std.testing.expect(std.meta.eql(Box.create(.{ 0, 0 }, .{ 10, 10 }), loaded_root.bounds()));

    var loaded_child = try accessor.loadNode(child.id());
    defer accessor.deinitNode(&loaded_child);
    try std.testing.expectEqual(@as(?u32, root_id), try loaded_child.getParent());
    try std.testing.expectEqual(@as(usize, 1), loaded_child.getLevel());
}

test "OrthTree paged model: rejects incompatible runtime settings" {
    const Model = fullaz.spatial.orthtree.models.paged.PagedModel(Cache, StorageManager, i32, 2, .little);

    var device = try Device.init(std.testing.allocator, 1024);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 8);
    defer cache.deinit();
    var storage_manager = StorageManager{};

    try std.testing.expectError(error.InvalidSettings, Model.init(&cache, &storage_manager, .{
        .max_leaf_entries = 0,
        .max_value_size = 64,
    }));
    try std.testing.expectError(error.InvalidSettings, Model.init(&cache, &storage_manager, .{
        .max_leaf_entries = 4,
        .max_value_size = 64,
        .node_page_kind = 7,
        .entry_page_kind = 7,
    }));
}

test "OrthTree paged model: inserts, queries, and removes byte values" {
    const Model = fullaz.spatial.orthtree.models.paged.PagedModel(Cache, StorageManager, i32, 2, .little);
    const Tree = TreeImpl(Model);
    const Box = Model.Box;
    const Collector = struct {
        seen_first: bool = false,
        seen_second: bool = false,

        fn collect(self: *@This(), _: Box, value: []const u8) !void {
            if (std.mem.eql(u8, value, "first")) {
                self.seen_first = true;
            }
            if (std.mem.eql(u8, value, "second")) {
                self.seen_second = true;
            }
        }
    };
    const MatchSecond = struct {
        fn call(_: *@This(), _: Box, value: []const u8) !bool {
            return std.mem.eql(u8, value, "second");
        }
    };

    var device = try Device.init(std.testing.allocator, 1024);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 8);
    defer cache.deinit();
    var storage_manager = StorageManager{};
    var model = try Model.init(&cache, &storage_manager, .{
        .max_leaf_entries = 4,
        .max_value_size = 64,
        .node_page_kind = 0x71,
        .entry_page_kind = 0x72,
    });
    defer model.deinit();
    var tree = Tree.init(&model);
    try tree.initRootBounds(Box.create(.{ 0, 0 }, .{ 100, 100 }));

    try tree.insert(Box.create(.{ 1, 1 }, .{ 2, 2 }), "first");
    try tree.insert(Box.create(.{ 3, 3 }, .{ 4, 4 }), "second");
    try std.testing.expectEqual(@as(usize, 2), try model.getEntriesCount());

    var collector = Collector{};
    try tree.query(Box.create(.{ 0, 0 }, .{ 10, 10 }), Collector.collect, &collector);
    try std.testing.expect(collector.seen_first);
    try std.testing.expect(collector.seen_second);

    var matcher = MatchSecond{};
    try std.testing.expect(try tree.remove(Box.create(.{ 0, 0 }, .{ 10, 10 }), MatchSecond.call, &matcher));
    try std.testing.expectEqual(@as(usize, 1), try model.getEntriesCount());

    collector = .{};
    try tree.query(Box.create(.{ 0, 0 }, .{ 10, 10 }), Collector.collect, &collector);
    try std.testing.expect(collector.seen_first);
    try std.testing.expect(!collector.seen_second);
}

test "OrthTree paged model: center-crossing entries span entry chunks" {
    const Model = fullaz.spatial.orthtree.models.paged.PagedModel(Cache, StorageManager, i32, 2, .little);
    const Tree = TreeImpl(Model);
    const Box = Model.Box;
    const Counter = struct {
        count: usize = 0,

        fn collect(self: *@This(), _: Box, _: []const u8) !void {
            self.count += 1;
        }
    };

    var device = try Device.init(std.testing.allocator, 128);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 32);
    defer cache.deinit();
    var storage_manager = StorageManager{};
    var model = try Model.init(&cache, &storage_manager, .{
        .max_leaf_entries = 1,
        .max_value_size = 24,
        .node_page_kind = 0x71,
        .entry_page_kind = 0x72,
    });
    defer model.deinit();
    var tree = Tree.init(&model);
    try tree.initRootBounds(Box.create(.{ 0, 0 }, .{ 100, 100 }));

    try tree.insert(Box.create(.{ 1, 1 }, .{ 2, 2 }), "lower");
    try tree.insert(Box.create(.{ 75, 75 }, .{ 76, 76 }), "upper");

    var payload: [24]u8 = undefined;
    const center_crossing = Box.create(.{ 45, 1 }, .{ 55, 2 });
    for (0..10) |index| {
        @memset(&payload, @intCast(index));
        try tree.insert(center_crossing, &payload);
    }
    try std.testing.expectEqual(@as(usize, 12), try model.getEntriesCount());

    const accessor = model.getAccessor();
    var root = try accessor.loadNode(storage_manager.root.?);
    defer accessor.deinitNode(&root);
    try std.testing.expect(!root.isLeaf());
    try std.testing.expectEqual(@as(usize, 10), root.size());
    const first_entry_page = (try root.getFirst()).?;
    const last_entry_page = (try root.getLast()).?;
    try std.testing.expect(first_entry_page != last_entry_page);

    var counter = Counter{};
    try tree.query(Box.create(.{ 0, 0 }, .{ 100, 100 }), Counter.collect, &counter);
    try std.testing.expectEqual(@as(usize, 12), counter.count);
}
