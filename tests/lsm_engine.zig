const std = @import("std");
const fullaz = @import("fullaz");
const models = fullaz.lsm.models;
const strategy = fullaz.lsm.strategy;
const flush_policy = fullaz.lsm.flush_policy;
const Lsm = fullaz.lsm.Lsm;
const SortedVector = fullaz.lsm.memtable.SortedVector;

const MemoryModel = models.MemoryModel(SortedVector);
const Engine = Lsm(MemoryModel, strategy.NaiveMergeAllStrategy, flush_policy.ThresholdFlushPolicy);

const never_flush = flush_policy.ThresholdFlushPolicy.init(null, null);

test "LSM engine: put then get, overwrite, missing key" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = Engine.init(&model, allocator, never_flush);
    defer lsm.deinit();

    try lsm.put("a", "1");
    try lsm.put("b", "2");

    try std.testing.expectEqualSlices(u8, "1", (try lsm.get("a")).?);
    try std.testing.expectEqualSlices(u8, "2", (try lsm.get("b")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try lsm.get("missing"));

    try lsm.put("a", "one");
    try std.testing.expectEqualSlices(u8, "one", (try lsm.get("a")).?);
}

test "LSM engine: delete makes a key invisible" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = Engine.init(&model, allocator, never_flush);
    defer lsm.deinit();

    try lsm.put("a", "1");
    try std.testing.expectEqualSlices(u8, "1", (try lsm.get("a")).?);

    try lsm.delete("a");
    try std.testing.expectEqual(@as(?[]const u8, null), try lsm.get("a"));

    try std.testing.expectEqual(@as(?[]const u8, null), try lsm.get("never-existed"));
}

test "LSM engine: put after delete makes the key visible again" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = Engine.init(&model, allocator, never_flush);
    defer lsm.deinit();

    try lsm.put("a", "1");
    try lsm.delete("a");
    try lsm.put("a", "2");

    try std.testing.expectEqualSlices(u8, "2", (try lsm.get("a")).?);
}

test "LSM engine: flushing an empty memtable is a no-op" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = Engine.init(&model, allocator, never_flush);
    defer lsm.deinit();

    try lsm.flush();
    try std.testing.expectEqual(@as(usize, 0), model.getAccessor().runCount());
}

test "LSM engine: flush moves data into a run, get() still finds it" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = Engine.init(&model, allocator, never_flush);
    defer lsm.deinit();

    try lsm.put("a", "1");
    try lsm.put("b", "2");

    try lsm.flush();
    try std.testing.expectEqual(@as(usize, 1), model.getAccessor().runCount());

    try std.testing.expectEqualSlices(u8, "1", (try lsm.get("a")).?);
    try std.testing.expectEqualSlices(u8, "2", (try lsm.get("b")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try lsm.get("missing"));
}

test "LSM engine: a tombstone written before flush still hides the key afterward" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = Engine.init(&model, allocator, never_flush);
    defer lsm.deinit();

    try lsm.put("a", "1");
    try lsm.delete("a");

    try lsm.flush();

    try std.testing.expectEqual(@as(?[]const u8, null), try lsm.get("a"));
}

test "LSM engine: byte-size threshold triggers an automatic flush" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = Engine.init(&model, allocator, flush_policy.ThresholdFlushPolicy.init(5, null));
    defer lsm.deinit();

    try lsm.put("a", "1");
    try std.testing.expectEqual(@as(usize, 0), model.getAccessor().runCount());

    try lsm.put("b", "2");
    try std.testing.expectEqual(@as(usize, 1), model.getAccessor().runCount());

    try std.testing.expectEqualSlices(u8, "1", (try lsm.get("a")).?);
    try std.testing.expectEqualSlices(u8, "2", (try lsm.get("b")).?);
}

test "LSM engine: count threshold triggers an automatic flush" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = Engine.init(&model, allocator, flush_policy.ThresholdFlushPolicy.init(null, 2));
    defer lsm.deinit();

    try lsm.put("a", "1");
    try std.testing.expectEqual(@as(usize, 0), model.getAccessor().runCount());

    try lsm.put("b", "2");
    try std.testing.expectEqual(@as(usize, 1), model.getAccessor().runCount());

    try std.testing.expectEqualSlices(u8, "1", (try lsm.get("a")).?);
    try std.testing.expectEqualSlices(u8, "2", (try lsm.get("b")).?);
}

test "LSM engine: delete also goes through maybeFlush" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = Engine.init(&model, allocator, flush_policy.ThresholdFlushPolicy.init(null, 1));
    defer lsm.deinit();

    try lsm.delete("a");

    try std.testing.expectEqual(@as(usize, 1), model.getAccessor().runCount());
    try std.testing.expectEqual(@as(?[]const u8, null), try lsm.get("a"));
}

test "LSM engine: a newer run shadows an older run for the same key" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = Engine.init(&model, allocator, never_flush);
    defer lsm.deinit();

    try lsm.put("a", "old");
    try lsm.flush();

    try lsm.put("a", "new");
    try lsm.flush();

    // flush() now auto-compacts (M14); with NaiveMergeAllStrategy, two runs
    // never survive side by side -- they merge back down to one immediately.
    try std.testing.expectEqual(@as(usize, 1), model.getAccessor().runCount());
    try std.testing.expectEqualSlices(u8, "new", (try lsm.get("a")).?);
}

test "LSM engine: compact() merges overlapping runs, drops the tombstone, keeps ascending order" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = Engine.init(&model, allocator, never_flush);
    defer lsm.deinit();

    try lsm.put("a", "1");
    try lsm.put("b", "2");
    try lsm.flush();
    try std.testing.expectEqual(@as(usize, 1), model.getAccessor().runCount());

    try lsm.put("b", "20");
    try lsm.put("c", "3");
    try lsm.flush();
    // NaiveMergeAllStrategy auto-compacts on every flush that leaves >= 2 runs.
    try std.testing.expectEqual(@as(usize, 1), model.getAccessor().runCount());

    try lsm.delete("a");
    try lsm.put("c", "30");
    try lsm.flush();
    try std.testing.expectEqual(@as(usize, 1), model.getAccessor().runCount());

    try std.testing.expectEqual(@as(?[]const u8, null), try lsm.get("a"));
    try std.testing.expectEqualSlices(u8, "20", (try lsm.get("b")).?);
    try std.testing.expectEqualSlices(u8, "30", (try lsm.get("c")).?);

    // Inspect the single surviving run directly: ascending, deduped, and
    // the "a" tombstone is gone entirely (not just shadowed) since a
    // NaiveMergeAllStrategy merge always reaches the oldest run.
    const acc = model.getAccessor();
    const run = (try acc.loadRun(acc.runIdAt(0))).?;
    defer acc.closeRun(run);

    var it = try run.iterator();
    defer it.deinit();

    const expect_keys = [_][]const u8{ "b", "c" };
    var i: usize = 0;
    while (try it.peek()) |e| : (try it.advance()) {
        try std.testing.expectEqualSlices(u8, expect_keys[i], e.key);
        i += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), i);
}
