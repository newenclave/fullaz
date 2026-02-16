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
    const num_insertions = 100;
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

test "WBpt remove: simple smoke" {
    const Model = MemoryModel(u8, 4);
    const Tree = wbpt.WeightedBpt(Model);

    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

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

test "WBpt remove: single leaf sequential removal" {
    const Model = MemoryModel(u8, 4);
    const Tree = wbpt.WeightedBpt(Model);

    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    _ = try tree.insert(0, "AAA");
    _ = try tree.insert(3, "BBB");
    _ = try tree.insert(6, "CCC");

    try expectTreeContent(std.testing.allocator, &tree, "AAABBBCCC");

    try tree.removeEntry(0);
    try expectTreeContent(std.testing.allocator, &tree, "BBBCCC");

    try tree.removeEntry(0);
    try expectTreeContent(std.testing.allocator, &tree, "CCC");

    try tree.removeEntry(0);
    try expectTreeContent(std.testing.allocator, &tree, "");
}

test "WBpt remove: remove from middle position" {
    const Model = MemoryModel(u8, 4);
    const Tree = wbpt.WeightedBpt(Model);

    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    _ = try tree.insert(0, "AAA");
    _ = try tree.insert(3, "BBB");
    _ = try tree.insert(6, "CCC");
    _ = try tree.insert(9, "DDD");

    try expectTreeContent(std.testing.allocator, &tree, "AAABBBCCCDDD");

    try tree.removeEntry(3);
    try expectTreeContent(std.testing.allocator, &tree, "AAACCCDDD");

    try tree.removeEntry(3);
    try expectTreeContent(std.testing.allocator, &tree, "AAADDD");
}

test "WBpt remove: underflow borrow from right sibling" {
    const Model = MemoryModel(u8, 4);
    const Tree = wbpt.WeightedBpt(Model);

    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    try insertAlphabet(&tree, 12);

    var before = try collectTreeContent(std.testing.allocator, &tree);
    defer before.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 12), before.items.len);

    try tree.removeEntry(0);
    try tree.removeEntry(0);

    var after = try collectTreeContent(std.testing.allocator, &tree);
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 10), after.items.len);
}

test "WBpt remove: underflow borrow from left sibling" {
    const Model = MemoryModel(u8, 4);
    const Tree = wbpt.WeightedBpt(Model);

    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    try insertAlphabet(&tree, 12);

    var before = try collectTreeContent(std.testing.allocator, &tree);
    defer before.deinit(std.testing.allocator);
    const len = before.items.len;

    try tree.removeEntry(len - 1);
    try tree.removeEntry(len - 2);

    var after = try collectTreeContent(std.testing.allocator, &tree);
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqual(len - 2, after.items.len);
}

test "WBpt remove: merge with right sibling" {
    const Model = MemoryModel(u8, 4);
    const Tree = wbpt.WeightedBpt(Model);

    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    for (0..15) |i| {
        const one = [_]u8{'A' + @as(u8, @intCast(i))};
        _ = try tree.insert(i, one[0..]);
    }

    try expectTreeContent(std.testing.allocator, &tree, "ABCDEFGHIJKLMNO");

    for (0..8) |_| {
        try tree.removeEntry(0);
    }

    var after = try collectTreeContent(std.testing.allocator, &tree);
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 7), after.items.len);
    try std.testing.expectEqualStrings("IJKLMNO", after.items);
}

test "WBpt remove: merge with left sibling" {
    const Model = MemoryModel(u8, 4);
    const Tree = wbpt.WeightedBpt(Model);

    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    for (0..15) |i| {
        const one = [_]u8{'A' + @as(u8, @intCast(i))};
        _ = try tree.insert(i, one[0..]);
    }

    try expectTreeContent(std.testing.allocator, &tree, "ABCDEFGHIJKLMNO");

    for (0..7) |_| {
        var current = try collectTreeContent(std.testing.allocator, &tree);
        const remove_at = current.items.len - 1;
        current.deinit(std.testing.allocator);
        try tree.removeEntry(remove_at);
    }

    var after = try collectTreeContent(std.testing.allocator, &tree);
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 8), after.items.len);
    try std.testing.expectEqualStrings("ABCDEFGH", after.items);
}

test "WBpt remove: cascading underflow leaf to inode" {
    const Model = MemoryModel(u8, 4);
    const Tree = wbpt.WeightedBpt(Model);

    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    for (0..25) |i| {
        const one = [_]u8{'A' + @as(u8, @intCast(i % 26))};
        _ = try tree.insert(i, one[0..]);
    }

    for (0..18) |_| {
        try tree.removeEntry(0);
    }

    var after = try collectTreeContent(std.testing.allocator, &tree);
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 7), after.items.len);
}

test "WBpt remove: tree height reduction" {
    const Model = MemoryModel(u8, 4);
    const Tree = wbpt.WeightedBpt(Model);

    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    for (0..20) |i| {
        const one = [_]u8{'A' + @as(u8, @intCast(i % 26))};
        _ = try tree.insert(i, one[0..]);
    }

    for (0..16) |_| {
        try tree.removeEntry(0);
    }

    var after = try collectTreeContent(std.testing.allocator, &tree);
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), after.items.len);
}

test "WBpt remove: remove until empty tree" {
    const Model = MemoryModel(u8, 4);
    const Tree = wbpt.WeightedBpt(Model);

    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    for (0..10) |i| {
        const one = [_]u8{'A' + @as(u8, @intCast(i))};
        _ = try tree.insert(i, one[0..]);
    }

    var before = try collectTreeContent(std.testing.allocator, &tree);
    defer before.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 10), before.items.len);

    for (0..10) |_| {
        try tree.removeEntry(0);
    }

    try expectTreeContent(std.testing.allocator, &tree, "");
}

test "WBpt remove: alternating insert and remove" {
    const Model = MemoryModel(u8, 4);
    const Tree = wbpt.WeightedBpt(Model);

    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    _ = try tree.insert(0, "AAA");
    _ = try tree.insert(3, "BBB");
    try expectTreeContent(std.testing.allocator, &tree, "AAABBB");

    try tree.removeEntry(0);
    try expectTreeContent(std.testing.allocator, &tree, "BBB");

    _ = try tree.insert(0, "XXX");
    try expectTreeContent(std.testing.allocator, &tree, "XXXBBB");

    try tree.removeEntry(3);
    try expectTreeContent(std.testing.allocator, &tree, "XXX");

    _ = try tree.insert(3, "YYY");
    _ = try tree.insert(6, "ZZZ");
    try expectTreeContent(std.testing.allocator, &tree, "XXXYYYZZZ");
}

test "WBpt remove: random removal stress test" {
    const Model = MemoryModel(u8, 4);
    const Tree = wbpt.WeightedBpt(Model);

    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    const num_entries = 30;
    for (0..num_entries) |i| {
        const one = [_]u8{'A' + @as(u8, @intCast(i % 26))};
        _ = try tree.insert(i, one[0..]);
    }

    var before = try collectTreeContent(std.testing.allocator, &tree);
    defer before.deinit(std.testing.allocator);
    try std.testing.expectEqual(num_entries, before.items.len);

    try tree.removeEntry(0);
    try tree.removeEntry(10);

    var current = try collectTreeContent(std.testing.allocator, &tree);
    const end_pos = current.items.len - 1;
    current.deinit(std.testing.allocator);
    try tree.removeEntry(end_pos);

    var removed_count: usize = 3;
    while (removed_count < num_entries) : (removed_count += 1) {
        var left = try collectTreeContent(std.testing.allocator, &tree);
        const is_empty = left.items.len == 0;
        left.deinit(std.testing.allocator);
        if (is_empty) break;
        try tree.removeEntry(0);
    }

    try expectTreeContent(std.testing.allocator, &tree, "");
}

test "WBpt remove: merge order detailed left sibling maintains order" {
    const Model = MemoryModel(u8, 4);
    const Tree = wbpt.WeightedBpt(Model);

    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    for (0..12) |i| {
        const one = [_]u8{'A' + @as(u8, @intCast(i))};
        _ = try tree.insert(i, one[0..]);
    }

    try expectTreeContent(std.testing.allocator, &tree, "ABCDEFGHIJKL");

    for (0..6) |_| {
        try tree.removeEntry(3);
    }

    try expectTreeContent(std.testing.allocator, &tree, "ABCJKL");
}

test "WBpt remove: merge order detailed right sibling maintains order" {
    const Model = MemoryModel(u8, 4);
    const Tree = wbpt.WeightedBpt(Model);

    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    for (0..12) |i| {
        const one = [_]u8{'A' + @as(u8, @intCast(i))};
        _ = try tree.insert(i, one[0..]);
    }

    try expectTreeContent(std.testing.allocator, &tree, "ABCDEFGHIJKL");

    for (0..6) |_| {
        try tree.removeEntry(0);
    }

    try expectTreeContent(std.testing.allocator, &tree, "GHIJKL");
}

test "WBpt remove: multiple merges preserve overall order" {
    const Model = MemoryModel(u8, 4);
    const Tree = wbpt.WeightedBpt(Model);

    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    for (0..20) |i| {
        const one = [_]u8{'A' + @as(u8, @intCast(i))};
        _ = try tree.insert(i, one[0..]);
    }

    try expectTreeContent(std.testing.allocator, &tree, "ABCDEFGHIJKLMNOPQRST");

    for (0..10) |_| {
        try tree.removeEntry(0);
    }

    try expectTreeContent(std.testing.allocator, &tree, "KLMNOPQRST");
}

test "WBpt remove: alternating removals maintain order during merges" {
    const Model = MemoryModel(u8, 4);
    const Tree = wbpt.WeightedBpt(Model);

    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    for (0..16) |i| {
        const one = [_]u8{'A' + @as(u8, @intCast(i))};
        _ = try tree.insert(i, one[0..]);
    }

    try expectTreeContent(std.testing.allocator, &tree, "ABCDEFGHIJKLMNOP");

    try tree.removeEntry(0);
    try tree.removeEntry(0);
    try expectTreeContent(std.testing.allocator, &tree, "CDEFGHIJKLMNOP");

    var current = try collectTreeContent(std.testing.allocator, &tree);
    const p_pos = current.items.len - 1;
    current.deinit(std.testing.allocator);
    try tree.removeEntry(p_pos);

    current = try collectTreeContent(std.testing.allocator, &tree);
    const o_pos = current.items.len - 1;
    current.deinit(std.testing.allocator);
    try tree.removeEntry(o_pos);

    try expectTreeContent(std.testing.allocator, &tree, "CDEFGHIJKLMN");
}

test "WBpt remove: merge order regression catch insert_at position bug" {
    const Model = MemoryModel(u8, 4);
    const Tree = wbpt.WeightedBpt(Model);

    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    const seq = "123456789";
    for (seq, 0..) |c, i| {
        const one = [_]u8{c};
        _ = try tree.insert(i, one[0..]);
    }

    try expectTreeContent(std.testing.allocator, &tree, "123456789");

    try tree.removeEntry(0);
    try tree.removeEntry(0);
    try tree.removeEntry(0);

    var result = try collectTreeContent(std.testing.allocator, &tree);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("456789", result.items);
    try std.testing.expectEqual(@as(u8, '4'), result.items[0]);
    try std.testing.expectEqual(@as(u8, '9'), result.items[result.items.len - 1]);
}

test "WBpt remove: weight propagation after borrow in multi-level tree" {
    const Model = MemoryModel(u8, 4);
    const Tree = wbpt.WeightedBpt(Model);

    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    const num_entries = 30;
    for (0..num_entries) |i| {
        const one = [_]u8{'A' + @as(u8, @intCast(i % 26))};
        _ = try tree.insert(i, one[0..]);
    }

    var initial = try collectTreeContent(std.testing.allocator, &tree);
    defer initial.deinit(std.testing.allocator);
    try std.testing.expectEqual(num_entries, initial.items.len);

    try tree.removeEntry(0);
    try tree.removeEntry(0);

    var after = try collectTreeContent(std.testing.allocator, &tree);
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqual(num_entries - 2, after.items.len);

    for (0..5) |_| {
        try tree.removeEntry(0);
    }

    var final = try collectTreeContent(std.testing.allocator, &tree);
    defer final.deinit(std.testing.allocator);
    try std.testing.expectEqual(num_entries - 7, final.items.len);
}

test "WBpt remove: deep tree weight consistency after multiple borrows" {
    const Model = MemoryModel(u8, 4);
    const Tree = wbpt.WeightedBpt(Model);

    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    const num_entries = 50;
    var insert_pos: usize = 0;
    for (0..num_entries) |i| {
        var buf: [16]u8 = undefined;
        const entry = try std.fmt.bufPrint(&buf, "{}_", .{i});
        _ = try tree.insert(insert_pos, entry);
        insert_pos += entry.len;
    }

    var before = try collectTreeContent(std.testing.allocator, &tree);
    defer before.deinit(std.testing.allocator);
    const before_size = before.items.len;

    try std.testing.expect(std.mem.indexOf(u8, before.items, "0_") != null);
    try std.testing.expect(std.mem.indexOf(u8, before.items, "49_") != null);

    for (0..10) |i| {
        var current = try collectTreeContent(std.testing.allocator, &tree);
        defer current.deinit(std.testing.allocator);

        if (current.items.len == 0) break;

        if (i % 2 == 0) {
            try tree.removeEntry(0);
        } else {
            const mid_pos = current.items.len / 2;
            if (mid_pos < current.items.len) {
                try tree.removeEntry(mid_pos);
            }
        }
    }

    var after = try collectTreeContent(std.testing.allocator, &tree);
    defer after.deinit(std.testing.allocator);

    try std.testing.expect(after.items.len < before_size);
    try std.testing.expect(after.items.len > 0);

    var iter = try tree.iterator();
    defer iter.deinit();

    var entry_count: usize = 0;
    var total_chars_from_cursor: usize = 0;

    while (!iter.isEnd()) {
        var v = try iter.get();
        defer v.deinit();
        const part = try v.get();
        try std.testing.expect(part.len > 0);
        entry_count += 1;
        total_chars_from_cursor += part.len;
        _ = try iter.next();
    }

    try std.testing.expectEqual(after.items.len, total_chars_from_cursor);
    try std.testing.expect(entry_count > 0);
}

test "WBpt remove: various tree configurations small" {
    const Model = MemoryModel(u8, 4);
    const Tree = wbpt.WeightedBpt(Model);

    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    _ = try tree.insert(0, "A");
    _ = try tree.insert(1, "B");
    _ = try tree.insert(2, "C");

    try tree.removeEntry(1);
    try expectTreeContent(std.testing.allocator, &tree, "AC");
}

test "WBpt remove: various tree configurations medium" {
    const Model = MemoryModel(u8, 4);
    const Tree = wbpt.WeightedBpt(Model);

    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    for (0..10) |i| {
        const one = [_]u8{'A' + @as(u8, @intCast(i))};
        _ = try tree.insert(i, one[0..]);
    }

    try tree.removeEntry(5);
    var result = try collectTreeContent(std.testing.allocator, &tree);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 9), result.items.len);
}

test "WBpt remove: various tree configurations large" {
    const Model = MemoryModel(u8, 4);
    const Tree = wbpt.WeightedBpt(Model);

    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    for (0..50) |i| {
        const one = [_]u8{'A' + @as(u8, @intCast(i % 26))};
        _ = try tree.insert(i, one[0..]);
    }

    for (0..25) |_| {
        // if (i == 14) {
        //     //@breakpoint();
        // }
        try tree.removeEntry(0);
        // std.debug.print("{} dump\n", .{i});
        // tree.dump();
        // std.debug.print("\n==========\n", .{});
    }

    var result = try collectTreeContent(std.testing.allocator, &tree);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 25), result.items.len);
}

test "WBpt remove: trying to merge with left" {
    const Model = MemoryModel(u8, 4);
    const Tree = wbpt.WeightedBpt(Model);

    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    for (0..8) |i| {
        var buf: [2]u8 = undefined;
        const val = try std.fmt.bufPrint(&buf, "{}", .{i});
        _ = try tree.insert(0, val);
    }

    var expected = try collectTreeContent(std.testing.allocator, &tree);
    defer expected.deinit(std.testing.allocator);

    var i: isize = 7;
    while (i >= 0) : (i -= 1) {
        if (i == 2) {
            //@breakpoint();
        }

        try tree.removeEntry(@as(usize, @intCast(i)));
        expected.shrinkRetainingCapacity(expected.items.len - 1);

        // std.debug.print("{} dump\n", .{i});
        // tree.dump();
        // std.debug.print("\n==========\n", .{});

        var current = try collectTreeContent(std.testing.allocator, &tree);
        defer current.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(expected.items, current.items);
    }
}

test "WBpt remove: insert remove leaks" {
    const Model = MemoryModel(u8, 4);

    var model = try Model.init(std.testing.allocator);
    defer model.deinit();

    var acc = model.getAccessor();
    var leaf = try acc.createLeaf();
    defer acc.deinitLeaf(&leaf);

    try leaf.insertWeight(0, "1");
    try leaf.removeAt(0);
}
