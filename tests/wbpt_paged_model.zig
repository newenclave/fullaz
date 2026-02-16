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

fn collectTreeContent(allocator: std.mem.Allocator, tree: anytype) !std.ArrayList(u8) {
    var content = try std.ArrayList(u8).initCapacity(allocator, 0);
    var iter = try tree.iterator();
    defer iter.deinit();

    while (!iter.isEnd()) {
        var val = try iter.get();
        defer val.deinit();
        try content.appendSlice(allocator, try val.get());
        _ = try iter.next();
    }

    return content;
}

fn expectTreeContent(allocator: std.mem.Allocator, tree: anytype, expected: []const u8) !void {
    var content = try collectTreeContent(allocator, tree);
    defer content.deinit(allocator);
    try std.testing.expectEqualStrings(expected, content.items);
}

fn insertAlphabet(tree: anytype, count: usize) !void {
    for (0..count) |i| {
        const one = [_]u8{'A' + @as(u8, @intCast(i % 26))};
        _ = try tree.insert(i, one[0..]);
    }
}

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
        std.debug.print("{s}", .{try entry.get()});
        _ = try cursor.next();
    }
    std.debug.print("\n", .{});
    //tree.dump();
}

test "WBpt paged remove: simple smoke" {
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

    for (0..10) |i| {
        var buf: [16]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "v{}", .{i});
        _ = try tree.insert(0, s);
    }

    try tree.removeEntry(0);
    for (0..9) |_| {
        try tree.removeEntry(0);
    }
    try expectTreeContent(std.testing.allocator, &tree, "");
}

test "WBpt paged: stress test - random insertions" {
    const maximum_insertion_to_dump = 100;
    const num_insertions = 24546;
    const log_interval = num_insertions / 10;
    const rebalance_policy = .neighbor_share;

    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const Model = PagedModel(PageCache, NoneStorageManager, void);
    const Tree = wbpt.WeightedBpt(Model);

    var store_mgr = NoneStorageManager{};
    var device = try Device.init(allocator, 1024);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 32);
    defer cache.deinit();
    var model = Model.init(&cache, &store_mgr, .{});

    var tree = Tree.init(&model, rebalance_policy);
    defer tree.deinit();

    // Fixed seed for reproducibility
    var prng = std.Random.DefaultPrng.init(42);

    // Use current time as seed for randomness
    //var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.nanoTimestamp())));
    const random = prng.random();

    std.debug.print("\n=== Stress Test: {} Random Insertions ===\n", .{num_insertions});

    // Track all insertions for verification
    const Insertion = struct {
        pos: usize,
        value: []const u8,
    };
    var insertions = try std.ArrayList(Insertion).initCapacity(allocator, 0);
    defer {
        for (insertions.items) |ins| {
            allocator.free(ins.value);
        }
        insertions.deinit(allocator);
    }

    var total_weight: usize = 0;

    // Perform random insertions
    for (0..num_insertions) |i| {
        // Generate random position (0 to current total_weight)
        const pos = if (total_weight == 0) 0 else random.uintLessThan(usize, total_weight + 1);

        // Generate random string of varying lengths (1 to 20)
        const len = random.intRangeAtMost(usize, 1, 20);
        var value = try allocator.alloc(u8, len);
        for (0..len) |j| {
            value[j] = 'a' + @as(u8, @intCast(random.uintLessThan(usize, 26)));
        }

        try insertions.append(allocator, .{
            .pos = pos,
            .value = value,
        });

        // if (i == 2193) {
        //     @breakpoint();
        //     std.debug.print("Tree total weight: {}\n", .{try tree.totalWeight()});
        // }

        _ = tree.insert(@as(u32, @intCast(pos)), value) catch |err| {
            std.debug.print("Insertion {} failed at pos {}: {}\n", .{ i, pos, err });
            return err;
        };
        total_weight += value.len;

        if ((i + 1) % log_interval == 0) {
            std.debug.print("Completed {} insertions, total_weight={}\n", .{ i + 1, total_weight });
        }
    }

    tree.dump();

    std.debug.print("\n=== Verification ===\n", .{});

    // Reconstruct the string from the tree
    var tree_content = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer tree_content.deinit(allocator);

    var iter = try tree.iterator();
    defer iter.deinit();

    var reconstructed_weight: usize = 0;
    while (!iter.isEnd()) {
        var val = try iter.get();
        defer val.deinit();
        const part = try val.get();
        try tree_content.appendSlice(allocator, part);
        reconstructed_weight += part.len;
        _ = try iter.next();
    }

    std.debug.print("Total insertions: {}\n", .{num_insertions});
    std.debug.print("Expected total weight: {}\n", .{total_weight});
    std.debug.print("Reconstructed weight: {}\n", .{reconstructed_weight});
    std.debug.print("Tree string length: {}\n", .{tree_content.items.len});
    std.debug.print("Tree total weight: {}\n", .{try tree.totalWeight()});

    //std.debug.print("Total nodes allocated: {}\n", .{acc.values.items.len});

    // Verify weights match
    try std.testing.expectEqual(total_weight, reconstructed_weight);
    try std.testing.expectEqual(total_weight, tree_content.items.len);

    // Now verify the content by simulating insertions on a simple string
    var expected = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer expected.deinit(allocator);

    for (insertions.items) |ins| {
        // if (ins.pos == 14249) {
        //     @breakpoint();
        // }
        try expected.insertSlice(allocator, ins.pos, ins.value);
    }

    //std.debug.print("{s}", .{expected.items});

    std.debug.print("Expected string length: {}\n", .{expected.items.len});

    // Verify content matches
    try std.testing.expectEqualSlices(u8, expected.items, tree_content.items);

    std.debug.print("SUCCESS: Tree content matches expected content!\n", .{});

    if (num_insertions <= maximum_insertion_to_dump) {
        std.debug.print("\n=== Final Tree Structure ===\n", .{});
        tree.dump();
    } else {
        std.debug.print("\n(Tree dump skipped for large test)\n", .{});
    }
}
