const std = @import("std");
const fullaz = @import("fullaz");
const models = fullaz.lsm.models;
const SortedVector = fullaz.lsm.memtable.SortedVector;

const MemoryModel = models.MemoryModel(SortedVector);

test "LSM MemoryModel: RunType satisfies the run contract" {
    comptime models.interfaces.assertRun(MemoryModel);
}

test "LSM MemoryModel: manually populated run round-trips through the accessor" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    const acc = model.getAccessor();

    // buildRun does not exist yet (M5) -- populate a run by hand instead.
    const table = try allocator.create(SortedVector);
    table.* = try SortedVector.init(allocator);
    try table.put("a", "1");

    try acc.run_table.append(allocator, table);
    try acc.run_order.append(allocator, 0);

    try std.testing.expectEqual(@as(usize, 1), acc.runCount());
    try std.testing.expectEqual(@as(usize, 0), acc.runIdAt(0));

    const run = (try acc.loadRun(0)).?;
    try std.testing.expectEqual(@as(usize, 0), run.id());
    try std.testing.expectEqual(@as(usize, 1), run.count());
    try std.testing.expectEqualSlices(u8, "1", (try run.get("a")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try run.get("missing"));

    acc.closeRun(run);
}

test "LSM MemoryModel: loadRun returns null for a destroyed slot" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    const acc = model.getAccessor();

    try acc.run_table.append(allocator, null);
    try acc.run_order.append(allocator, 0);

    try std.testing.expectEqual(@as(?MemoryModel.RunType, null), try acc.loadRun(0));
}
