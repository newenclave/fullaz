const std = @import("std");
const MemoryLog = @import("fullaz").device.MemoryLog;

test "MemoryLog preserves its configured offset type" {
    const Log = MemoryLog(u64);
    var log = try Log.init(std.testing.allocator);
    defer log.deinit();

    try log.append("fullaz");
    try std.testing.expectEqual(@as(u64, 6), log.size());

    var bytes: [3]u8 = undefined;
    try log.readAt(2, &bytes);
    try std.testing.expectEqualSlices(u8, "lla", &bytes);
    try std.testing.expectError(error.BadData, log.readAt(5, &bytes));
}
