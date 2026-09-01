const bpt = @import("fullaz").bpt;
const algos = @import("fullaz").core.algorithm;

const MemoryModel = bpt.models.MemoryModel;

const std = @import("std");
const expect = std.testing.expect;

const Io = std.Io;

fn getRandomSeed() !u64 {
    const io = std.testing.io;
    var seed: u64 = undefined;
    Io.random(io, std.mem.asBytes(&seed));
    return seed;
}

pub fn BptTest(comptime KeyType: type, maximum_elements: usize, comptime OrderCmp: anytype) type {
    return struct {
        const Self = @This();

        const Model = MemoryModel(KeyType, maximum_elements, OrderCmp);

        model: Model,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) !Self {
            return Self{
                .model = try Model.init(allocator),
                .allocator = allocator,
            };
        }

        fn createTree(self: *Self) !bpt.Bpt(Model) {
            return bpt.Bpt(Model).init(&self.model, .neighbor_share);
        }

        pub fn deinit(self: *Self) void {
            self.model.deinit();
        }
    };
}

fn strCmp(a: []const u8, b: []const u8) algos.Order {
    // compare null-terminated strings
    var min_len = a.len;
    if (b.len < min_len) {
        min_len = b.len;
    }

    for (0..min_len) |i| {
        if (a[i] == 0 and b[i] == 0) {
            return .eq;
        } else if (a[i] == 0) {
            return .lt;
        } else if (b[i] == 0) {
            return .gt;
        }
        if (a[i] < b[i]) {
            return .lt;
        } else if (a[i] > b[i]) {
            return .gt;
        }
    }

    if (a.len < b.len) {
        return .lt;
    } else if (a.len > b.len) {
        return .gt;
    }
    return .eq;
}

fn exerciseMemoryNodeCreation(allocator: std.mem.Allocator) !void {
    const Model = MemoryModel(u32, 5, algos.CmpNum(u32).asc);
    var model = try Model.init(allocator);
    defer model.deinit();
    const accessor = model.accessor();

    const leaf = try accessor.createLeaf();
    accessor.deinitLeaf(leaf);
    const inode = try accessor.createInode();
    accessor.deinitInode(inode);
}

test "Bpt memory model releases partial node creation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseMemoryNodeCreation,
        .{},
    );
}

fn format(allocator: std.mem.Allocator, comptime fmt: []const u8, options: anytype) ![:0]u8 {
    return std.fmt.allocPrintSentinel(allocator, fmt, options, 0) catch @panic("Something went wrong");
}

test "Bpt Create with Memory model" {
    const allocator = std.testing.allocator;
    const TreeTest = BptTest(u32, 5, algos.CmpNum(u32).asc);
    var tree_test = try TreeTest.init(allocator);
    defer tree_test.deinit();

    var bptree = try tree_test.createTree();
    defer bptree.deinit();

    for (0..500) |i| {
        const key = @as(u32, @intCast(i));
        var buf: [32]u8 = undefined;
        const value = try std.fmt.bufPrint(&buf, "{}", .{key});
        _ = try bptree.insert(key, value);
    }

    for (0..500) |i| {
        const key = @as(u32, @intCast(i));
        if (try bptree.find(key)) |itr_const| {
            defer itr_const.deinit();

            const value = (try itr_const.get()).?.value;
            const expected_value = try format(allocator, "{:0}", .{key});
            defer allocator.free(expected_value);

            // Include the sentinel in the slice: expected_value has len N but the sentinel is at [N]
            try expect(strCmp(value[0..], expected_value[0 .. expected_value.len + 1]) == .eq);
        } else {
            try expect(false);
        }
    }
}

test "Bpt Find non-existing key" {
    const allocator = std.testing.allocator;

    const TreeTest = BptTest(u32, 5, algos.CmpNum(u32).asc);
    var tree_test = try TreeTest.init(allocator);
    defer tree_test.deinit();

    var bptree = try tree_test.createTree();
    defer bptree.deinit();

    for (0..100) |i| {
        const key = @as(u32, @intCast(i * 2)); // Insert even keys only
        var buf: [32]u8 = undefined;
        const value = try std.fmt.bufPrint(&buf, "{}", .{key});
        _ = try bptree.insert(key, value);
    }

    // Now try to find odd keys, which do not exist
    for (0..100) |i| {
        const key = @as(u32, @intCast(i * 2 + 1)); // Odd keys
        const result = try bptree.find(key);
        try expect(result == null);
    }
}

test "Bpt remove values" {
    const allocator = std.testing.allocator;

    const TreeTest = BptTest(u32, 5, algos.CmpNum(u32).asc);
    var tree_test = try TreeTest.init(allocator);
    defer tree_test.deinit();

    var bptree = try tree_test.createTree();
    defer bptree.deinit();

    for (0..100) |i| {
        const key = @as(u32, @intCast(i));
        var buf: [32]u8 = undefined;
        const value = try std.fmt.bufPrint(&buf, "{}", .{key});
        _ = try bptree.insert(key, value);
    }

    // Now remove keys 0 to 49
    for (0..100) |i| {
        if (i % 2 == 0) continue;
        const key = @as(u32, @intCast(i));
        try expect(try bptree.remove(key));
    }

    // Verify removal
    for (0..100) |i| {
        const key = @as(u32, @intCast(i));
        if (try bptree.find(key)) |itr_const| {
            defer itr_const.deinit();
            if (i % 2 != 0) {
                try expect(false); // Should have been removed
            }

            const value = (try itr_const.get()).?.value;
            const expected_value = try format(tree_test.allocator, "{:0}", .{key});
            defer tree_test.allocator.free(expected_value);

            // Include the sentinel in the slice: expected_value has len N but the sentinel is at [N]
            try expect(strCmp(value[0..], expected_value[0 .. expected_value.len + 1]) == .eq);
        } else {
            if (i % 2 == 0) {
                try expect(false); // Should exist
            }
        }
    }
}

test "Bpt Random insertion" {
    const allocator = std.testing.allocator;

    const TreeTest = BptTest(u32, 5, algos.CmpNum(u32).asc);
    var tree_test = try TreeTest.init(allocator);
    defer tree_test.deinit();

    var bptree = try tree_test.createTree();
    defer bptree.deinit();

    var prng = std.Random.DefaultPrng.init(try getRandomSeed());
    const random = prng.random();

    const total_inserts = 1000;
    var inserted_keys = try std.ArrayList(u32).initCapacity(allocator, total_inserts);
    errdefer inserted_keys.deinit(allocator);

    for (0..total_inserts) |_| {
        const key = random.int(u32);
        var buf: [32]u8 = undefined;
        const value = try std.fmt.bufPrint(&buf, "{}", .{key});
        if (try bptree.insert(key, value)) {
            try inserted_keys.append(allocator, key);
        }
    }

    // Verify all inserted keys
    for (inserted_keys.items) |key| {
        if (try bptree.find(key)) |itr_const| {
            defer itr_const.deinit();
            const value = (try itr_const.get()).?.value;
            const expected_value = try format(tree_test.allocator, "{:0}", .{key});
            defer tree_test.allocator.free(expected_value);

            // Include the sentinel in the slice: expected_value has len N but the sentinel is at [N]
            try expect(strCmp(value[0..], expected_value[0 .. expected_value.len + 1]) == .eq);
        } else {
            try expect(false); // Key should exist
        }
    }

    inserted_keys.deinit(allocator);
}

test "Bpt Update values" {
    const allocator = std.testing.allocator;

    const TreeTest = BptTest(u32, 5, algos.CmpNum(u32).asc);
    var tree_test = try TreeTest.init(allocator);
    defer tree_test.deinit();

    var bptree = try tree_test.createTree();
    defer bptree.deinit();

    for (0..100) |i| {
        const key = @as(u32, @intCast(i));
        var buf: [32]u8 = undefined;
        const value = try std.fmt.bufPrint(&buf, "{}", .{key});
        _ = try bptree.insert(key, value);
    }

    // Update values
    for (0..100) |i| {
        const key = @as(u32, @intCast(i));
        var buf: [32]u8 = undefined;
        const new_value = try std.fmt.bufPrint(&buf, "updated_{}", .{key});
        _ = try bptree.update(key, new_value); // Insert should update existing key
    }

    // Verify updates
    for (0..100) |i| {
        const key = @as(u32, @intCast(i));
        if (try bptree.find(key)) |itr_const| {
            defer itr_const.deinit();
            const value = (try itr_const.get()).?.value;
            const expected_value = try format(tree_test.allocator, "updated_{:0}", .{key});
            defer tree_test.allocator.free(expected_value);

            // Include the sentinel in the slice: expected_value has len N but the sentinel is at [N]
            try expect(strCmp(value[0..], expected_value[0 .. expected_value.len + 1]) == .eq);
        } else {
            try expect(false); // Key should exist
        }
    }
}

test "BPT memory value editor coordinates, finishes, rolls back, and rejects stale iterators" {
    const allocator = std.testing.allocator;
    const TreeTest = BptTest(u32, 5, algos.CmpNum(u32).asc);
    var tree_test = try TreeTest.init(allocator);
    defer tree_test.deinit();
    var tree = try tree_test.createTree();
    defer tree.deinit();
    var same_model_tree = try tree_test.createTree();
    defer same_model_tree.deinit();

    try std.testing.expect(try tree.insert(1, "abcdefghijklmnop"));
    var editor = (try tree.openValueEditor(1)).?;
    try std.testing.expectError(error.ValueEditorActive, same_model_tree.openValueEditor(1));
    try std.testing.expectError(error.ValueEditorActive, tree.insert(2, "qrstuvwxyzabcdef"));
    const value = try editor.valueMut();
    value[0] = 'Z';
    try editor.finish();
    try std.testing.expectError(error.EditorInvalidated, editor.valueMut());
    try std.testing.expectError(error.EditorInvalidated, editor.finish());

    var committed = (try tree.find(1)).?;
    defer committed.deinit();
    try std.testing.expectEqualSlices(u8, "Zbcdefghijklmnop", (try committed.get()).?.value);

    var rollback = (try tree.openValueEditor(1)).?;
    (try rollback.valueMut())[1] = 'Y';
    rollback.deinit();
    var restored = (try tree.find(1)).?;
    defer restored.deinit();
    try std.testing.expectEqualSlices(u8, "Zbcdefghijklmnop", (try restored.get()).?.value);

    var iterator = (try tree.find(1)).?;
    defer iterator.deinit();
    try std.testing.expect(try tree.insert(2, "qrstuvwxyzabcdef"));
    try std.testing.expectError(error.StaleIterator, iterator.editValue());
}

test "Some stress test" {
    const allocator = std.testing.allocator;

    const KeyType = f32;

    const TreeTest = BptTest(f32, 5, algos.CmpNum(f32).asc);
    var tree_test = try TreeTest.init(allocator);
    defer tree_test.deinit();

    var bptree = try tree_test.createTree();
    defer bptree.deinit();

    var prng = std.Random.DefaultPrng.init(try getRandomSeed());
    const random = prng.random();

    for (0..500) |_| {
        //_ = i;
        _ = random.int(u32) % 200;
        const key = random.int(u32) % 500;
        var buf: [32]u8 = undefined;
        const value = try std.fmt.bufPrint(&buf, "{}", .{key});
        _ = try bptree.insert(@as(KeyType, @floatFromInt(key)), value);
    }

    for (0..500) |i| {
        _ = i;
        _ = random.int(u32) % 200;
        const key = random.int(u32) % 500;
        var buf: [32]u8 = undefined;
        const value = try std.fmt.bufPrint(&buf, "{}", .{key + 666_1000});
        _ = try bptree.update(@as(KeyType, @floatFromInt(key)), value);
    }

    for (0..413) |_| {
        const key = random.int(u32) % 500;
        _ = try bptree.remove(@floatFromInt(key));
    }

    if (try bptree.iterator()) |itr_const| {
        var itr = itr_const;
        defer itr.deinit();

        while (try itr.next()) |vals| {
            _ = vals.key.*;
        }

        while (try itr.prev()) |vals| {
            _ = vals.key.*;
        }
        while (try itr.next()) |vals| {
            _ = vals.key.*;
        }
    }

    if (try bptree.iteratorFromEnd()) |itr_const| {
        var itr = itr_const;
        defer itr.deinit();
        while (try itr.prev()) |vals| {
            if (try bptree.find(vals.key.*)) |fi_const| {
                var fi = fi_const;
                defer fi.deinit();
                if (try fi.get()) |v| {
                    _ = v;
                    try expect(true);
                } else {
                    try expect(false);
                }
            }
        }
        while (try itr.next()) |vals| {
            _ = vals.key.*;
        }
    }

    if (try bptree.lowerBound(10000)) |itr_const| {
        var itr = itr_const;
        defer itr.deinit();
        while (try itr.prev()) |vals| {
            _ = vals.key.*;
        }

        while (try itr.next()) |vals| {
            _ = vals.key.*;
        }
    }
}
