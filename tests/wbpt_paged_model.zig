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

        try leaf.setParent(123);
        try leaf.setPrev(456);
        try leaf.setNext(789);

        var leaf_load = try model.accessor.loadLeaf(leaf.id());
        defer model.getAccessor().deinitLeaf(&leaf_load);

        try std.testing.expect(try leaf.getParent() == 123);
        try std.testing.expect(try leaf.getPrev() == 456);
        try std.testing.expect(try leaf.getNext() == 789);

        try std.testing.expect(try leaf.getParent() == try leaf_load.getParent());
        try std.testing.expect(try leaf.getPrev() == try leaf_load.getPrev());
        try std.testing.expect(try leaf.getNext() == try leaf_load.getNext());

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
    var device = try Device.init(allocator, 110);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();
    var model = Model.init(&cache, &store_mgr, .{});

    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    var leaf = try model.accessor.createLeaf();
    defer model.getAccessor().deinitLeaf(&leaf);

    try leaf.insertAt(0, "Test!");
    try leaf.insertWeight(3, "111111111111");
    try leaf.removeAt(0);

    const ci = try leaf.canInsertWeight(2, "XXXXXXXXXXXXXXXXXXXXXX");
    std.debug.print("Can insert at weight 3: {}\n", .{ci});
    try leaf.insertWeight(2, "XXXXXXXXXXXXXXXXXXXXXX");

    std.debug.print("Leaf size: {}\n", .{try leaf.size()});
    std.debug.print("Leaf capacity: {}\n", .{try leaf.capacity()});
    std.debug.print("Leaf total weight: {}\n", .{try leaf.totalWeight()});

    for (0..try leaf.size()) |i| {
        const entry = try leaf.getValue(i);
        std.debug.print("Entry {}: weight={}, value={s}\n", .{ i, try entry.weight(), try entry.get() });
    }
}

test "WBpt paged: tree create, insert" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const Model = PagedModel(PageCache, NoneStorageManager, void);
    const Tree = wbpt.WeightedBpt(Model);

    var store_mgr = NoneStorageManager{};
    var device = try Device.init(allocator, 256);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();
    var model = Model.init(&cache, &store_mgr, .{});

    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    _ = try tree.insert(0, "Root!");
    _ = try tree.insert(3, "111111111111");
    _ = try tree.insert(2, "XXXXXXXXXXXXXXXXXXXXXX");
    _ = try tree.insert(20, "YYYYYYYYYYYYYYYYYYYY");
    _ = try tree.insert(30, "ZZZZZZZZZZZZZZZZZZZ");
    _ = try tree.insert(40, "00000000000000000000");
    _ = try tree.insert(50, "111111111111111111111");
    _ = try tree.insert(60, "2222222222222222222222");
    _ = try tree.insert(70, "3333333333333333333333");
    _ = try tree.insert(80, "44444444444444444444444");
    _ = try tree.insert(90, "555555555555555555555555");
    _ = try tree.insert(100, "666666666666666666666666");
    _ = try tree.insert(110, "77777777777777777777777777");

    var cursor = try tree.iterator();
    defer cursor.deinit();

    std.debug.print("Real tree iteration! total weight: {}\n", .{try tree.totalWeight()});

    while (!cursor.isEnd()) {
        const entry = try cursor.get();
        std.debug.print("    Entry: weight={}, value={s}\n", .{ try entry.weight(), try entry.get() });
        _ = try cursor.next();
    }
    tree.dump();
}
