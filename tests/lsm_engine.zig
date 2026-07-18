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

    try std.testing.expectEqual(@as(usize, 2), model.getAccessor().runCount());
    try std.testing.expectEqualSlices(u8, "new", (try lsm.get("a")).?);
}
