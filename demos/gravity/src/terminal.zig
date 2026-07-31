const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;

const WindowsInput = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;
    const key_event: windows.WORD = 0x0001;

    const KeyEventRecord = extern struct {
        key_down: windows.BOOL,
        repeat_count: windows.WORD,
        virtual_key_code: windows.WORD,
        virtual_scan_code: windows.WORD,
        character: extern union {
            unicode: windows.WCHAR,
            ascii: u8,
        },
        control_key_state: windows.DWORD,
    };

    const InputRecord = extern struct {
        event_type: windows.WORD,
        _: windows.WORD,
        event: extern union {
            key: KeyEventRecord,
            padding: [16]u8,
        },
    };

    extern "kernel32" fn GetNumberOfConsoleInputEvents(handle: windows.HANDLE, count: *windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn ReadConsoleInputW(handle: windows.HANDLE, buffer: *InputRecord, length: windows.DWORD, read: *windows.DWORD) callconv(.winapi) windows.BOOL;
};

pub const Size = struct {
    columns: usize = 80,
    rows: usize = 24,
};

pub fn dimensions(io: Io) Size {
    const file = Io.File.stdout();
    if (builtin.os.tag == .windows) {
        var info = std.os.windows.CONSOLE.USER_IO.GET_SCREEN_BUFFER_INFO;
        return switch (info.operate(io, file) catch return .{}) {
            .SUCCESS => .{
                .columns = @intCast(info.Data.dwWindowSize.X),
                .rows = @intCast(info.Data.dwWindowSize.Y),
            },
            else => .{},
        };
    }

    var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const result = (io.operate(.{ .device_io_control = .{
        .file = file,
        .code = std.posix.T.IOCGWINSZ,
        .arg = &size,
    } }) catch return .{}).device_io_control;
    if (result < 0 or size.col == 0 or size.row == 0) return .{};
    return .{ .columns = size.col, .rows = size.row };
}

pub fn clear(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.writeAll("\x1b[2J\x1b[H");
}

pub fn home(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.writeAll("\x1b[H");
}

pub fn restore(writer: *Io.Writer) void {
    writer.writeAll("\x1b[0m\x1b[?25h\n") catch {};
    writer.flush() catch {};
}

pub fn pollByte() ?u8 {
    if (comptime builtin.os.tag == .windows) {
        var event_count: std.os.windows.DWORD = 0;
        if (!WindowsInput.GetNumberOfConsoleInputEvents(Io.File.stdin().handle, &event_count).toBool()) return null;
        while (event_count > 0) : (event_count -= 1) {
            var record: WindowsInput.InputRecord = undefined;
            var read: std.os.windows.DWORD = 0;
            if (!WindowsInput.ReadConsoleInputW(Io.File.stdin().handle, &record, 1, &read).toBool() or read == 0) return null;
            if (record.event_type != WindowsInput.key_event or !record.event.key.key_down.toBool()) continue;
            const character = record.event.key.character.unicode;
            if (character <= 0x7f) return @intCast(character);
        }
        return null;
    }

    var fds = [_]std.posix.pollfd{.{
        .fd = Io.File.stdin().handle,
        .events = .{ .IN = true },
        .revents = .{},
    }};
    const count = std.posix.poll(&fds, 0) catch return null;
    if (count == 0) return null;
    var byte: [1]u8 = undefined;
    const read = std.posix.read(Io.File.stdin().handle, &byte) catch return null;
    return if (read == 1) byte[0] else null;
}
