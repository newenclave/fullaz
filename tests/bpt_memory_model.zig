const bpt = @import("fullaz").bpt;
const algos = @import("fullaz").algorithm;

const MemoryModel = bpt.models.MemoryModel;

const std = @import("std");
const expect = std.testing.expect;

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

fn format(allocator: std.mem.Allocator, comptime fmt: []const u8, options: anytype) ![:0]u8 {
    return std.fmt.allocPrintSentinel(allocator, fmt, options, 0) catch @panic("Something went wrong");
}

test "Bpt Create with Memory model" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }

    const allocator = gpa.allocator();
    const TreeTest = BptTest(u32, 5, algos.CmpNum(u32).asc);
    var tree_test = try TreeTest.init(gpa.allocator());
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }

    const TreeTest = BptTest(u32, 5, algos.CmpNum(u32).asc);
    var tree_test = try TreeTest.init(gpa.allocator());
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }

    const TreeTest = BptTest(u32, 5, algos.CmpNum(u32).asc);
    var tree_test = try TreeTest.init(gpa.allocator());
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }

    const TreeTest = BptTest(u32, 5, algos.CmpNum(u32).asc);
    var tree_test = try TreeTest.init(gpa.allocator());
    defer tree_test.deinit();

    var bptree = try tree_test.createTree();
    defer bptree.deinit();

    var prng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const random = prng.random();

    const total_inserts = 1000;
    var inserted_keys = try std.ArrayList(u32).initCapacity(gpa.allocator(), total_inserts);
    errdefer inserted_keys.deinit(gpa.allocator());

    for (0..total_inserts) |_| {
        const key = random.int(u32);
        var buf: [32]u8 = undefined;
        const value = try std.fmt.bufPrint(&buf, "{}", .{key});
        if (try bptree.insert(key, value)) {
            try inserted_keys.append(gpa.allocator(), key);
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

    inserted_keys.deinit(gpa.allocator());
}

test "Bpt Update values" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }

    const TreeTest = BptTest(u32, 5, algos.CmpNum(u32).asc);
    var tree_test = try TreeTest.init(gpa.allocator());
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
