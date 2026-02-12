const std = @import("std");
const wbpt = @import("fullaz").weighted_bpt;
const algos = @import("fullaz").core.algorithm;
const PageCacheT = @import("fullaz").storage.page_cache.PageCache;
const dev = @import("fullaz").device;

const PagedModel = wbpt.models.paged.PagedModel;

const String = std.ArrayList(u8);

const NoneStorageManager = struct {
    pub const Self = @This();
    pub const PageId = u32;
    pub const Error = error{};
    root_block_id: ?u32 = null,

    pub fn getRoot(self: *const @This()) ?u32 {
        return self.root_block_id;
    }

    pub fn setRoot(self: *@This(), root: ?u32) Error!void {
        self.root_block_id = root;
        // Persist to disk header, etc.
    }

    pub fn hasRoot(self: *const @This()) bool {
        return self.root_block_id != null;
    }

    pub fn destroyPage(_: *@This(), id: PageId) Error!void {
        _ = id;
        // Implement page destruction logic, e.g., add to free list
    }
};

const NoneValuePolicy = struct {};

test "WBpt paged: Create with Memory model" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const Model = PagedModel(PageCache, NoneStorageManager, void);
    const Tree = wbpt.WeightedBpt(Model);

    var store_mgr = NoneStorageManager{};
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();
    var model = Model.init(&cache, &store_mgr, .{});

    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    {
        var leaf = try model.accessor.createLeaf();
        defer model.getAccessor().deinitLeaf(&leaf);
        var leaf_load = try model.accessor.loadLeaf(leaf.id());
        defer model.getAccessor().deinitLeaf(&leaf_load);

        try std.testing.expect(leaf.id() == leaf_load.id());
    }
    {
        var inode = try model.accessor.createInode();
        defer model.getAccessor().deinitInode(&inode);
        var inode_load = try model.accessor.loadInode(inode.id());
        defer model.getAccessor().deinitInode(&inode_load);

        try std.testing.expect(inode.id() == inode_load.id());
    }
}

test "WBpt paged: Insert, get" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const Model = PagedModel(PageCache, NoneStorageManager, void);
    const Tree = wbpt.WeightedBpt(Model);

    var store_mgr = NoneStorageManager{};
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();
    var model = Model.init(&cache, &store_mgr, .{});

    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    var leaf = try model.accessor.createLeaf();
    defer model.getAccessor().deinitLeaf(&leaf);

    try leaf.insertAt(0, "Test!");
    try leaf.insertWeight(3, "111");
    std.debug.print("Leaf size: {}\n", .{try leaf.size()});

    for (0..try leaf.size()) |i| {
        const entry = try leaf.getValue(i);
        std.debug.print("Entry {}: weight={}, value={s}\n", .{ i, entry.weight(), entry.get() });
    }
}
