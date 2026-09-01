const std = @import("std");
const fullaz = @import("fullaz");

fn compare(_: void, left: []const u8, right: []const u8) std.math.Order {
    return std.mem.order(u8, left, right);
}

const Model = fullaz.storage.slot_heap.models.Memory(compare, void);
const Heap = fullaz.storage.slot_heap.Heap(Model);

const CheckSummary = struct {
    key: [4]u8,
    winner: Model.LocationType,
    entries: u64,
};

fn locationsEqual(left: Model.LocationType, right: Model.LocationType) bool {
    return left.page_id == right.page_id and left.slot_id == right.slot_id;
}

fn checkNode(
    model: *Model,
    node_id: Model.NodeIdType,
    expected_parent: ?Model.NodeIdType,
    eligible: *std.AutoHashMap(Model.NodeIdType, void),
) !CheckSummary {
    const accessor = model.accessor();
    if (try accessor.isLeafId(node_id)) {
        var leaf = (try accessor.loadLeaf(node_id)).?;
        defer accessor.deinitLeaf(leaf);
        try std.testing.expectEqual(expected_parent, try leaf.getParent());
        const count = try leaf.size();
        try std.testing.expect(count > 0);
        var index: usize = 1;
        while (index < count) : (index += 1) {
            const parent = (index - 1) / 2;
            try std.testing.expect((try model.compareKeys(
                try leaf.getKey(index),
                try leaf.getKey(parent),
            )) != .lt);
        }
        var key: [4]u8 = undefined;
        @memcpy(&key, try leaf.getKey(0));
        return .{
            .key = key,
            .winner = .{ .page_id = node_id, .slot_id = 0 },
            .entries = @intCast(count),
        };
    }

    var inode = (try accessor.loadInode(node_id)).?;
    defer accessor.deinitInode(inode);
    try std.testing.expectEqual(expected_parent, try inode.getParent());
    const count = try inode.size();
    try std.testing.expect(count > 0);
    if (expected_parent == null) {
        try std.testing.expect(count >= 2);
    }
    const is_eligible = count < try inode.capacity();
    try std.testing.expectEqual(is_eligible, try inode.isAvailableLinked());
    if (is_eligible) {
        try eligible.put(node_id, {});
    }

    var total: u64 = 0;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        if (index > 0) {
            const parent = (index - 1) / 2;
            try std.testing.expect((try model.compareKeys(
                try inode.getKey(index),
                try inode.getKey(parent),
            )) != .lt);
        }
        const child_id = try inode.getChild(index);
        const child = try checkNode(model, child_id, node_id, eligible);
        try std.testing.expectEqualSlices(u8, &child.key, try inode.getKey(index));
        try std.testing.expect(locationsEqual(child.winner, try inode.getWinner(index)));
        total += child.entries;
    }

    var key: [4]u8 = undefined;
    @memcpy(&key, try inode.getKey(0));
    return .{
        .key = key,
        .winner = try inode.getWinner(0),
        .entries = total,
    };
}

fn validateHeap(model: *Model) !void {
    const accessor = model.accessor();
    var eligible = std.AutoHashMap(Model.NodeIdType, void).init(std.testing.allocator);
    defer eligible.deinit();

    const root = accessor.getRoot() orelse {
        try std.testing.expectEqual(@as(?Model.LocationType, null), accessor.getCachedTop());
        try std.testing.expectEqual(@as(u64, 0), try model.getEntriesCount());
        return;
    };
    const summary = try checkNode(model, root, null, &eligible);
    try std.testing.expect(locationsEqual(summary.winner, accessor.getCachedTop().?));
    try std.testing.expectEqual(summary.entries, try model.getEntriesCount());

    for (1..32) |level| {
        var current = try accessor.getAvailableInode(level);
        var previous: ?Model.NodeIdType = null;
        var traversed: usize = 0;
        while (current) |inode_id| {
            traversed += 1;
            try std.testing.expect(traversed <= eligible.count());
            var inode = (try accessor.loadInode(inode_id)).?;
            defer accessor.deinitInode(inode);
            try std.testing.expectEqual(level, try inode.getLevel());
            try std.testing.expectEqual(previous, try inode.getAvailablePrev());
            try std.testing.expect(eligible.remove(inode_id));
            previous = inode_id;
            current = try inode.getAvailableNext();
        }
    }
    try std.testing.expectEqual(@as(usize, 0), eligible.count());
}

fn encodeKey(value: u32) [4]u8 {
    var key: [4]u8 = undefined;
    std.mem.writeInt(u32, &key, value, .big);
    return key;
}

fn initModel() !Model {
    return Model.init(std.testing.allocator, {}, .{
        .key_size = 4,
        .maximum_value_size = 16,
        .leaf_capacity_bytes = 32,
        .inode_capacity = 2,
        .max_levels = 32,
    });
}

test "SlotHeap memory model satisfies the contract" {
    comptime fullaz.storage.slot_heap.models.interfaces.assertModel(Model);
}

test "SlotHeap memory: empty top and pop fail" {
    var model = try initModel();
    defer model.deinit();
    var heap = Heap.init(&model);

    try std.testing.expect(try heap.isEmpty());
    try std.testing.expectError(error.EmptySet, heap.top());
    try std.testing.expectError(error.EmptySet, heap.pop());
}

test "SlotHeap memory: push, top, and pop preserve priority order" {
    var model = try initModel();
    defer model.deinit();
    var heap = Heap.init(&model);

    try heap.push("0003", "three");
    try heap.push("0001", "one");
    try heap.push("0002", "two");

    const expected = [_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "0001", .value = "one" },
        .{ .key = "0002", .value = "two" },
        .{ .key = "0003", .value = "three" },
    };
    for (expected, 0..) |item, index| {
        var top = try heap.top();
        try std.testing.expectEqualSlices(u8, item.key, try top.key());
        try std.testing.expectEqualSlices(u8, item.value, try top.value());
        top.deinit();
        try heap.pop();
        try std.testing.expectEqual(@as(u64, expected.len - index - 1), try heap.count());
    }
    try std.testing.expect(try heap.isEmpty());
}

test "SlotHeap memory: grows and contracts a multi-level tree" {
    var model = try initModel();
    defer model.deinit();
    var heap = Heap.init(&model);

    var keys: [24][4]u8 = undefined;
    for (0..keys.len) |index| {
        _ = try std.fmt.bufPrint(&keys[index], "{d:0>4}", .{keys.len - index});
        try heap.push(&keys[index], "value");
    }
    try std.testing.expect((try heap.height()) >= 2);
    try validateHeap(&model);

    for (1..keys.len + 1) |expected| {
        var expected_key: [4]u8 = undefined;
        _ = try std.fmt.bufPrint(&expected_key, "{d:0>4}", .{expected});
        var top = try heap.top();
        try std.testing.expectEqualSlices(u8, &expected_key, try top.key());
        top.deinit();
        try heap.pop();
        try validateHeap(&model);
    }
    try std.testing.expectEqual(@as(usize, 0), try heap.height());
    try std.testing.expect(try heap.isEmpty());
}

test "SlotHeap memory: duplicate priorities are all retained" {
    var model = try initModel();
    defer model.deinit();
    var heap = Heap.init(&model);

    try heap.push("0001", "a");
    try heap.push("0001", "b");
    try heap.push("0001", "c");
    try std.testing.expectEqual(@as(u64, 3), try heap.count());

    for (0..3) |_| {
        var top = try heap.top();
        try std.testing.expectEqualSlices(u8, "0001", try top.key());
        top.deinit();
        try heap.pop();
    }
}

test "SlotHeap memory: validates key and value sizes" {
    var model = try initModel();
    defer model.deinit();
    var heap = Heap.init(&model);

    try std.testing.expectError(error.BadKeyLength, heap.push("bad", "value"));
    try std.testing.expectError(error.ValueTooLarge, heap.push("0001", "value-too-large-for-page"));
    try std.testing.expectEqual(@as(u64, 0), try heap.count());
}

test "SlotHeap memory: rejects growth past the configured maximum level" {
    var model = try Model.init(std.testing.allocator, {}, .{
        .key_size = 4,
        .maximum_value_size = 16,
        .leaf_capacity_bytes = 32,
        .inode_capacity = 2,
        .max_levels = 2,
    });
    defer model.deinit();
    var heap = Heap.init(&model);

    var keys: [13][4]u8 = undefined;
    for (0..keys.len) |index| {
        _ = try std.fmt.bufPrint(&keys[index], "{d:0>4}", .{index});
    }
    var reached_limit = false;
    for (&keys) |*key| {
        heap.push(key, "v") catch |err| {
            try std.testing.expectEqual(error.MaxDepth, err);
            reached_limit = true;
            break;
        };
    }
    try std.testing.expect(reached_limit);
}

test "SlotHeap memory: randomized interleaved operations match an oracle" {
    var model = try initModel();
    defer model.deinit();
    var heap = Heap.init(&model);
    var oracle: std.ArrayList(u32) = .empty;
    defer oracle.deinit(std.testing.allocator);

    var prng = std.Random.DefaultPrng.init(0x5107_4EAF);
    const random = prng.random();
    for (0..800) |step| {
        const should_push = oracle.items.len == 0 or random.intRangeLessThan(u8, 0, 100) < 62;
        if (should_push) {
            const value = random.intRangeLessThan(u32, 0, 10_000);
            const key = encodeKey(value);
            try heap.push(&key, "v");
            try oracle.append(std.testing.allocator, value);
        } else {
            var minimum_index: usize = 0;
            for (oracle.items[1..], 1..) |value, index| {
                if (value < oracle.items[minimum_index]) {
                    minimum_index = index;
                }
            }
            const expected = oracle.items[minimum_index];
            var top = try heap.top();
            try std.testing.expectEqual(expected, std.mem.readInt(u32, (try top.key())[0..4], .big));
            top.deinit();
            try heap.pop();
            _ = oracle.swapRemove(minimum_index);
        }
        try std.testing.expectEqual(@as(u64, @intCast(oracle.items.len)), try heap.count());
        if (step % 17 == 0) {
            try validateHeap(&model);
        }
    }
    try validateHeap(&model);
}

test "SlotHeap memory: top value editor commits, rolls back, and blocks structural mutation" {
    var model = try initModel();
    defer model.deinit();
    var heap = Heap.init(&model);
    try heap.push("0001", "one");
    try heap.push("0002", "two");

    var editor = try heap.openValueEditor();
    @memcpy(try editor.valueMut(), "ONE");
    try std.testing.expectError(error.ValueEditorActive, heap.openValueEditor());
    try std.testing.expectError(error.ValueEditorActive, heap.push("0000", "zero"));
    try std.testing.expectError(error.ValueEditorActive, heap.pop());
    try std.testing.expectError(error.ValueEditorActive, heap.clear());
    try editor.finish();
    try std.testing.expectError(error.EditorInvalidated, editor.valueMut());
    editor.deinit();

    var top = try heap.top();
    try std.testing.expectEqualSlices(u8, "0001", try top.key());
    try std.testing.expectEqualSlices(u8, "ONE", try top.value());
    top.deinit();
    try std.testing.expectEqual(@as(u64, 2), try heap.count());

    var peek = try heap.mutableTop();
    var rollback = try peek.editValue();
    @memcpy(try rollback.valueMut(), "bad");
    rollback.deinit();
    peek.deinit();

    top = try heap.top();
    defer top.deinit();
    try std.testing.expectEqualSlices(u8, "ONE", try top.value());
    try validateHeap(&model);
}
