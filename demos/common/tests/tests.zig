const std = @import("std");
const common = @import("demo_common");

const terminal = common.terminal;
const testing = std.testing;

fn rendered(buffer: []u8, comptime call: anytype) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try call(&writer);
    return writer.buffered();
}

test "terminal: clear wipes the screen and homes the cursor" {
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("\x1b[2J\x1b[H", try rendered(&buffer, terminal.clear));
}

// Frames are redrawn from the home position with per-line erase rather than a
// full clear, which is what stops the terminal flickering.
test "terminal: home moves the cursor without clearing" {
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("\x1b[H", try rendered(&buffer, terminal.home));
}

test "terminal: restore resets attributes and shows the cursor" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    terminal.restore(&writer);

    try testing.expectEqualStrings("\x1b[0m\x1b[?25h\r\n", writer.buffered());
}

test "terminal: an unknown console size falls back to eighty by twenty-four" {
    const fallback = terminal.Size{};

    try testing.expectEqual(@as(usize, 80), fallback.columns);
    try testing.expectEqual(@as(usize, 24), fallback.rows);
}
