const std = @import("std");
const fullaz_db = @import("fullaz-db");

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
