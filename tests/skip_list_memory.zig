const std = @import("std");
const skip_list = @import("fullaz").skip_list;

const MemoryModel = skip_list.models.Memory;
const SkipList = skip_list.List;

fn keyCmp(_: anytype, k1: anytype, k2: @TypeOf(k1)) std.math.Order {
    if (k1 < k2) {
        return .lt;
    } else if (k1 > k2) {
        return .gt;
    } else {
        return .eq;
    }
}

fn collectLevel0(comptime SL: type, sl: *SL, allocator: std.mem.Allocator) !std.ArrayList(SL.KeyIn) {
    const acc = sl.getAccessor();
    var list = try std.ArrayList(SL.KeyIn).initCapacity(allocator, 0);
    errdefer list.deinit(allocator);
    var curr_pid = try acc.getRoot(0);
    while (curr_pid) |pid| {
        var node = try acc.loadNode(pid);
        defer acc.deinitNode(&node);
        try list.append(allocator, try node.getKey());
        curr_pid = try node.getNext(0);
    }
    return list;
}

test "SkipList: create an instance" {
    const MModel = MemoryModel(u32, u32, keyCmp, void);
    const SLIst = SkipList(MModel);

    var prng: std.Random.DefaultPrng = .init(2341);
    const rand = prng.random();

    var model = try MModel.init(std.heap.page_allocator, 2, rand);
    defer model.deinit();

    var list = SLIst.init(&model);
    defer list.deinit();
}

test "SkipList: random levels generation" {
    var prng: std.Random.DefaultPrng = .init(77665);
    const rand = prng.random();

    const MModel = MemoryModel(u32, u32, keyCmp, void);

    var model = try MModel.init(std.testing.allocator, 5, rand);
    defer model.deinit();

    var map: std.AutoHashMap(usize, u32) = .init(std.testing.allocator);
    defer map.deinit();

    for (0..1_000_000) |_| {
        const level = try model.getAccessor().generateLevel(2);
        if (map.get(level)) |v| {
            _ = try map.fetchPut(level, v + 1);
        } else {
            try map.put(level, 1);
        }
    }

    for (0..try model.getMaxLevel()) |i| {
        if (map.get(i)) |v| {
            std.debug.print("Level {d}: {d}\n", .{ i, v });
        }
    }
}

test "SkipList: remove existing keys. simple case" {
    var prng: std.Random.DefaultPrng = .init(42);
    const rand = prng.random();
    const Model = MemoryModel(u32, u32, keyCmp, void);
    var model = try Model.init(std.testing.allocator, 4, rand);
    defer model.deinit();

    const SL = SkipList(Model);
    var sl = SL.init(&model);

    const keys = [_]u32{ 10, 20, 30, 40, 50 };
    for (keys) |k| try sl.insert(k, k);

    try sl.remove(30);
    try sl.remove(10);
    try sl.remove(50);

    var collected = try collectLevel0(SL, &sl, std.testing.allocator);
    defer collected.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u32, &.{ 20, 40 }, collected.items);
}
