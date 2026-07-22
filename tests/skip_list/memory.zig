const std = @import("std");
const skip_list = @import("fullaz").skip_list;

const MemoryModel = skip_list.models.Memory;
const SkipList = skip_list.List;

var globalTestStart: u64 = 0;
var globalTag: []const u8 = "";

fn getNowTimestamp() u64 {
    const io = std.testing.io;
    const timestamp = std.Io.Clock.real.now(io);
    const millis = @abs(timestamp.toMilliseconds());
    return millis;
}

fn beforeTest(tag: []const u8) void {
    globalTestStart = getNowTimestamp();
    globalTag = tag;
}

fn timestampPrint(comptime name: []const u8, params: anytype) void {
    const io = std.testing.io;
    const timestamp = std.Io.Clock.real.now(io);
    const millis = @abs(timestamp.toMilliseconds()) - globalTestStart;
    const hours = millis / (1000 * 60 * 60);
    const mins = (millis / (1000 * 60)) % 60;
    const seconds = (millis / 1000) % 60;

    std.debug.print("{d:0>2}:{:0>2}:{:0>2}.{d:0>4} [{s}]: ", .{ hours, mins, seconds, @mod(millis, 1000), globalTag });
    std.debug.print(name, params);
}

fn keyCmp(_: anytype, k1: anytype, k2: @TypeOf(k1)) std.math.Order {
    if (k1 < k2) {
        return .lt;
    } else if (k1 > k2) {
        return .gt;
    } else {
        return .eq;
    }
}

fn keyDumper(value: *const u32) void {
    std.debug.print("{d}; ", .{value.*});
}

fn valueDumper(_: *const u32) void {
    //std.debug.print("={d}; ", .{value.*});
}

fn collectLevel0(comptime SL: type, sl: *SL, allocator: std.mem.Allocator) !std.ArrayList(SL.KeyIn) {
    const acc = sl.getModel().getAccessor();
    var list = try std.ArrayList(SL.KeyIn).initCapacity(allocator, 0);
    errdefer list.deinit(allocator);
    var curr_pid = try acc.getRoot(0);
    while (curr_pid) |pid| {
        var node = try acc.loadNode(pid);
        defer acc.deinitNode(&node);
        const nodeKey = try node.getKey();
        try list.append(allocator, sl.model.keyOutAsIn(nodeKey));
        curr_pid = try node.getNext(0);
    }
    return list;
}

test "SkipList: create an instance" {
    beforeTest(@src().fn_name);

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
    beforeTest(@src().fn_name);

    var prng: std.Random.DefaultPrng = .init(getNowTimestamp());
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

test "SkipList: iterator test" {
    beforeTest(@src().fn_name);
    var prng: std.Random.DefaultPrng = .init(getNowTimestamp());
    const rand = prng.random();
    const Model = MemoryModel(u32, u32, keyCmp, void);
    var model = try Model.init(std.testing.allocator, 8, rand);
    defer model.deinit();

    const SL = SkipList(Model);
    var sl = SL.init(&model);

    var desiderKeys = try std.ArrayList(u32).initCapacity(std.testing.allocator, 100);
    defer desiderKeys.deinit(std.testing.allocator);

    timestampPrint("Inserting keys...\n", .{});
    for (0..100_000) |k| {
        const next = @as(u32, (@as(u32, @intCast(k)) + 1) * 10);
        try desiderKeys.append(std.testing.allocator, next);
        try sl.insert(next, next);
    }

    timestampPrint("Iterating keys...\n", .{});
    var count: usize = 0;
    var expected_key: u32 = 0;

    var it = try sl.begin();
    defer it.deinit();
    while (!it.isEnd()) {
        expected_key += 10;
        count += 1;
        try std.testing.expectEqual((try it.key()).*, expected_key);
        _ = try it.next();
    }

    timestampPrint("Done iterating keys.\n", .{});
    try std.testing.expectEqual(count, desiderKeys.items.len);
}

test "SkipList: iterator remove test" {
    beforeTest(@src().fn_name);
    var prng: std.Random.DefaultPrng = .init(getNowTimestamp());
    const rand = prng.random();
    const Model = MemoryModel(u32, u32, keyCmp, void);
    var model = try Model.init(std.testing.allocator, 8, rand);
    defer model.deinit();

    const SL = SkipList(Model);
    var sl = SL.init(&model);

    var desiderKeys = try std.ArrayList(u32).initCapacity(std.testing.allocator, 100);
    defer desiderKeys.deinit(std.testing.allocator);

    timestampPrint("Inserting keys...\n", .{});
    for (0..10_000) |k| {
        const next = @as(u32, (@as(u32, @intCast(k)) + 1) * 10);
        try desiderKeys.append(std.testing.allocator, next);
        try sl.insert(next, next);
    }

    timestampPrint("Iterating keys...\n", .{});
    var count: usize = 0;
    var expected_key: u32 = 0;

    const half = desiderKeys.items.len / 2;

    timestampPrint("start removing the keys...\n", .{});

    for (0..half) |id| {
        const next = @as(u32, (@as(u32, @intCast(id * 2)) + 1) * 10);
        var it = try sl.find(next);
        defer it.deinit();

        try std.testing.expectEqual((try it.key()).*, next);
        it = try sl.removeItr(it);
        expected_key += 20;
        count += 1;
        if (!it.isEnd()) {
            try std.testing.expectEqual((try it.key()).*, expected_key);
        }
    }

    _ = try sl.dump(keyDumper, valueDumper);

    timestampPrint("Done removing the keys...\n", .{});
    try std.testing.expectEqual(count, half);
}
