const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

test "fullaz-db: chainStore memory database commits and rolls back" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add(
        "blob",
        fullaz_db.chainStore(.{}),
    );
    const Database = fullaz_db.MemoryDatabase(Schema);
    var database = try Database.init(std.testing.allocator, .{
        .page_size = 128,
        .cache_frames = 8,
    });
    defer database.deinit();

    {
        var transaction = try database.begin();
        const blob = transaction.get("blob");
        try blob.append("hello");
        try blob.append(" world");
        try transaction.commit();
    }
    {
        var output: [16]u8 = undefined;
        const blob = database.getConst("blob");
        try std.testing.expectEqual(@as(u64, 11), try blob.size());
        try std.testing.expectEqual(@as(usize, 11), try blob.readAt(0, &output));
        try std.testing.expectEqualStrings("hello world", output[0..11]);
    }
    {
        var transaction = try database.begin();
        const blob = transaction.get("blob");
        try blob.writeAt(6, "zig");
        try transaction.rollback();
    }
    {
        var output: [16]u8 = undefined;
        const blob = database.getConst("blob");
        try std.testing.expectEqual(@as(usize, 11), try blob.readAt(0, &output));
        try std.testing.expectEqualStrings("hello world", output[0..11]);
    }
}

test "fullaz-db: chainStore mutable proxy expires with its transaction" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add(
        "blob",
        fullaz_db.chainStore(.{}),
    );
    const Database = fullaz_db.MemoryDatabase(Schema);
    var database = try Database.init(std.testing.allocator, .{
        .page_size = 128,
        .cache_frames = 8,
    });
    defer database.deinit();

    var transaction = try database.begin();
    const blob = transaction.get("blob");
    try transaction.commit();
    try std.testing.expectError(error.TransactionInactive, blob.append("late"));
}

test "fullaz-db: weightedSequence edits byte offsets" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add(
        "sequence",
        fullaz_db.weightedSequence(.{ .maximum_chunk_size = 3 }),
    );
    const Database = fullaz_db.MemoryDatabase(Schema);
    var database = try Database.init(std.testing.allocator, .{
        .page_size = 512,
        .cache_frames = 16,
    });
    defer database.deinit();

    var transaction = try database.begin();
    const sequence = transaction.get("sequence");
    try sequence.append("abcdef");
    try sequence.replace(2, 3, "XYZ");
    try transaction.commit();

    var output: [16]u8 = undefined;
    const sequence_read = database.getConst("sequence");
    try std.testing.expectEqual(@as(usize, 6), try sequence_read.readAt(0, &output));
    try std.testing.expectEqualStrings("abXYZf", output[0..6]);

    var rollback_transaction = try database.begin();
    try rollback_transaction.get("sequence").erase(1, 4);
    try rollback_transaction.rollback();

    try std.testing.expectEqual(@as(usize, 6), try sequence_read.readAt(0, &output));
    try std.testing.expectEqualStrings("abXYZf", output[0..6]);
}
