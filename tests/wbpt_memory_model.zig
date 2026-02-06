const std = @import("std");
const wbpt = @import("fullaz").weighted_bpt;
const algos = @import("fullaz").core.algorithm;

const MemoryModel = wbpt.models.memory.Model;

const String = std.ArrayList(u8);

test "WBpt: Create with Memory model" {
    const Model = MemoryModel(u8, 16);
    const Tree = wbpt.WeightedBpt(Model);

    const allocator = std.testing.allocator;
    var model = try Model.init(allocator);
    defer model.deinit();
    var acc = model.getAccessor();
    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    var leaf = try acc.createLeaf();
    var load_leaf = try acc.loadLeaf(leaf.id());

    try std.testing.expect(leaf.id() == load_leaf.id());

    defer acc.deinitLeaf(&leaf);
    defer acc.deinitLeaf(&load_leaf);
    try std.testing.expect(try acc.isLeaf(leaf.id()));
}

test "WBpt: insertion weight into a list" {
    const Model = MemoryModel(u8, 4);

    const allocator = std.testing.allocator;
    var model = try Model.init(allocator);
    defer model.deinit();
    var acc = model.getAccessor();

    var leaf = try acc.createLeaf();
    defer acc.deinitLeaf(&leaf);

    try leaf.insertWeight(0, "Hello world");
    try leaf.insertWeight(6, "Zig is great");
    for (0..try leaf.size()) |i| {
        var val = try leaf.getValue(i);
        defer val.deinit();
        std.debug.print("Leaf Value {}: {s}\n", .{ i, try val.get() });
    }
}

test "WBpt: create inode" {
    const Model = MemoryModel(u8, 4);

    const allocator = std.testing.allocator;
    var model = try Model.init(allocator);
    defer model.deinit();
    var acc = model.getAccessor();

    var inode = try acc.createInode();
    defer acc.deinitInode(&inode);
}

test "WBpt: insertion" {
    const Model = MemoryModel(u8, 4);
    const Tree = wbpt.WeightedBpt(Model);

    const allocator = std.testing.allocator;
    var model = try Model.init(allocator);
    defer model.deinit();

    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    _ = try tree.insert(0, "Hello world");
    _ = try tree.insert(5, ",");
    _ = try tree.insert(15, "!");
    _ = try tree.insert(7, " 42 ");
    _ = try tree.insert(9, " -- ");
    _ = try tree.insert(11, " !!!!!! ");
    _ = try tree.insert(15, " ??? ");
    _ = try tree.insert(0, "Lets begin!");
    //_ = try tree.insert(1000, "end");
    //try tree.removeEntry(0);

    var acc = model.getAccessor();
    var leaf = try acc.loadLeaf(0);
    defer acc.deinitLeaf(&leaf);
    for (0..try leaf.size()) |i| {
        var val = try leaf.getValue(i);
        defer val.deinit();
        std.debug.print("Leaf Value {}: {s}\n", .{ i, try val.get() });
    }
    tree.dump();

    std.debug.print("total size: {}\n", .{try tree.totalWeight()});
    var iter = try tree.iterator();
    defer iter.deinit();
    while (!iter.isEnd()) {
        var val = try iter.get();
        defer val.deinit();
        std.debug.print("{s}", .{try val.get()});
        _ = try iter.next();
    }
    std.debug.print("\n", .{});

    while (!iter.isBegin()) {
        _ = try iter.prev();
        if (iter.isBegin()) {
            break;
        }
        var val = try iter.get();
        defer val.deinit();
        std.debug.print("{s}", .{try val.get()});
    }
    std.debug.print("\n", .{});
}

test "WBpt: stress test - random insertions" {
    const maximum_insertion_to_dump = 100;
    const num_insertions = 2500;
    const log_interval = num_insertions / 10;
    const maximum_elements = 4;
    const rebalance_policy = .neighbor_share;

    const Model = MemoryModel(u8, maximum_elements);
    const Tree = wbpt.WeightedBpt(Model);

    const allocator = std.testing.allocator;
    var model = try Model.init(allocator);
    defer model.deinit();
    const acc = model.getAccessor();

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

        _ = try tree.insert(pos, value);
        total_weight += value.len;

        if ((i + 1) % log_interval == 0) {
            std.debug.print("Completed {} insertions, total_weight={}\n", .{ i + 1, total_weight });
        }
    }

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
    std.debug.print("Total nodes allocated: {}\n", .{acc.values.items.len});

    // Verify weights match
    try std.testing.expectEqual(total_weight, reconstructed_weight);
    try std.testing.expectEqual(total_weight, tree_content.items.len);

    // Now verify the content by simulating insertions on a simple string
    var expected = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer expected.deinit(allocator);

    for (insertions.items) |ins| {
        try expected.insertSlice(allocator, ins.pos, ins.value);
    }

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
