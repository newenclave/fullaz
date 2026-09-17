const std = @import("std");
const fullaz = @import("fullaz");

test "FileLog: read-only open reads data and rejects mutations" {
    const Log = fullaz.device.FileLog(u32);
    const io = std.testing.io;
    const path = ".zig-cache/file_log_read_only.log";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        var log = try Log.create(io, path);
        defer log.deinit();
        try log.append("committed bytes");
        try log.sync();
    }
    {
        var log = try Log.openReadOnly(io, path);
        defer log.deinit();
        try std.testing.expectEqual(@as(u32, 15), log.size());
        var actual: [15]u8 = undefined;
        try log.readAt(0, &actual);
        try std.testing.expectEqualStrings("committed bytes", &actual);
        try std.testing.expectError(error.ReadOnly, log.append("more"));
        try std.testing.expectError(error.ReadOnly, log.sync());
        try std.testing.expectError(error.ReadOnly, log.reset());
        try std.testing.expectError(error.ReadOnly, log.truncate(0));
    }

    var log = try Log.open(io, path);
    defer log.deinit();
    try std.testing.expectEqual(@as(u32, 15), log.size());
}
