const std = @import("std");
const fullaz = @import("fullaz");
const models = fullaz.lsm.models;
const SortedVector = fullaz.lsm.memtable.SortedVector;

const MemoryModel = models.MemoryModel(SortedVector);

test "LSM MemoryModel: RunType satisfies the run contract" {
    comptime models.interfaces.assertRun(MemoryModel);
}

test "LSM MemoryModel: loadRun returns null for a destroyed slot" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    const acc = model.getAccessor();

    try acc.ctx.run_table.append(allocator, null);
    try acc.ctx.run_order.append(allocator, 0);

    try std.testing.expectEqual(@as(?MemoryModel.RunType, null), try acc.loadRun(0));
}

test "LSM MemoryModel: AccessorType satisfies the run-accessor contract" {
    comptime models.interfaces.assertRunAccessor(MemoryModel);
}

test "LSM MemoryModel: satisfies the full model contract" {
    comptime models.interfaces.assertModel(MemoryModel);
}

test "LSM MemoryModel: buildRun drains a cursor into a readable run" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    const acc = model.getAccessor();
    try acc.activeMemtable().put("a", "1");
    try acc.activeMemtable().put("b", "2");

    var it = try acc.activeMemtable().iterator();
    const run_id = try acc.buildRun(&it);
    it.deinit();

    const run = (try acc.loadRun(run_id)).?;
    try std.testing.expectEqual(@as(usize, 2), run.count());
    try std.testing.expectEqualSlices(u8, "1", (try run.get("a")).?);
    try std.testing.expectEqualSlices(u8, "2", (try run.get("b")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try run.get("missing"));
    acc.closeRun(run);
}

test "LSM MemoryModel: Bloom gate never produces a false negative" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    const acc = model.getAccessor();

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&kbuf, "key-{d}", .{i});
        try acc.activeMemtable().put(key, key);
    }

    var it = try acc.activeMemtable().iterator();
    const run_id = try acc.buildRun(&it);
    it.deinit();

    const run = (try acc.loadRun(run_id)).?;

    i = 0;
    while (i < 200) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&kbuf, "key-{d}", .{i});
        try std.testing.expectEqualSlices(u8, key, (try run.get(key)).?);
    }

    i = 0;
    while (i < 50) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&kbuf, "absent-{d}", .{i});
        try std.testing.expectEqual(@as(?[]const u8, null), try run.get(key));
    }

    acc.closeRun(run);
}

test "LSM MemoryModel: publish with an empty span inserts the new run at the front" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    const acc = model.getAccessor();
    try acc.activeMemtable().put("a", "1");
    var it = try acc.activeMemtable().iterator();
    const run_id = try acc.buildRun(&it);
    it.deinit();

    try acc.publish(&.{}, run_id);

    try std.testing.expectEqual(@as(usize, 1), acc.runCount());
    try std.testing.expectEqual(run_id, acc.runIdAt(0));
}

test "LSM MemoryModel: publish replaces a contiguous span and destroys the old runs" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    const acc = model.getAccessor();

    // Three flushes: put one key, build a run from it, publish at the front.
    try acc.activeMemtable().put("a", "1");
    var it0 = try acc.activeMemtable().iterator();
    const run0 = try acc.buildRun(&it0);
    it0.deinit();
    try acc.activeMemtable().reset();
    try acc.publish(&.{}, run0);

    try acc.activeMemtable().put("b", "2");
    var it1 = try acc.activeMemtable().iterator();
    const run1 = try acc.buildRun(&it1);
    it1.deinit();
    try acc.activeMemtable().reset();
    try acc.publish(&.{}, run1);

    try acc.activeMemtable().put("c", "3");
    var it2 = try acc.activeMemtable().iterator();
    const run2 = try acc.buildRun(&it2);
    it2.deinit();
    try acc.activeMemtable().reset();
    try acc.publish(&.{}, run2);

    // Newest-first: [run2, run1, run0].
    try std.testing.expectEqual(@as(usize, 3), acc.runCount());
    try std.testing.expectEqual(run2, acc.runIdAt(0));
    try std.testing.expectEqual(run1, acc.runIdAt(1));
    try std.testing.expectEqual(run0, acc.runIdAt(2));

    // Merge the two newest runs (a contiguous span) into one new run.
    var merged = try SortedVector.init(allocator);
    defer merged.deinit();
    try merged.put("b", "2");
    try merged.put("c", "3");
    var merged_it = try merged.iterator();
    const new_run = try acc.buildRun(&merged_it);
    merged_it.deinit();

    try acc.publish(&.{ run2, run1 }, new_run);

    try std.testing.expectEqual(@as(usize, 2), acc.runCount());
    try std.testing.expectEqual(new_run, acc.runIdAt(0));
    try std.testing.expectEqual(run0, acc.runIdAt(1));

    // The replaced runs are destroyed, not just unlisted.
    try std.testing.expectEqual(@as(?MemoryModel.RunType, null), try acc.loadRun(run2));
    try std.testing.expectEqual(@as(?MemoryModel.RunType, null), try acc.loadRun(run1));

    const run = (try acc.loadRun(new_run)).?;
    try std.testing.expectEqualSlices(u8, "2", (try run.get("b")).?);
    try std.testing.expectEqualSlices(u8, "3", (try run.get("c")).?);
    acc.closeRun(run);
}
