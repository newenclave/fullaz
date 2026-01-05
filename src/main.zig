const std = @import("std");
const fullaz = @import("root.zig");

// sandbox main function
//here I'm going to test some code snippets

pub fn main() !void {
    const Variadic = fullaz.slots.Variadic;
    var buffer = [_]u8{0} ** 1024;
    var slot = try Variadic(u16, .little, false).init(&buffer);
    slot.formatHeader();
    std.debug.print("Variadic slot initialized with body size: {}\n", .{slot.body.len});
    std.debug.print("Header entry count: {}\n", .{slot.headerConst().entry_count.get()});
    std.debug.print("Available space: {}\n", .{slot.availableSpace()});
    std.debug.print("Can insert 100 bytes: {}\n", .{try slot.canInsert(100)});
    std.debug.print("Can insert 2000 bytes: {}\n", .{try slot.canInsert(2000)});

    _ = try slot.insert(&[_]u8{0});
    _ = try slot.insert(&[_]u8{ 0, 1 });
    _ = try slot.insert(&[_]u8{ 0, 1, 2 });
    _ = try slot.insert(&[_]u8{ 0, 1, 2, 3 });
    _ = try slot.insert(&[_]u8{ 0, 1, 2, 3, 4 });
    _ = try slot.insert(&[_]u8{ 0, 1, 2, 3, 4, 5 });
    _ = try slot.insert(&[_]u8{ 0, 1, 2, 3, 4, 5, 6 });

    var value = try slot.get(0);
    std.debug.print("Retrieved 0 entry value: {any}\n", .{value});

    value = try slot.get(1);
    std.debug.print("Retrieved entry value: {any}\n", .{value});

    value = try slot.getMut(1);
    std.debug.print("Retrieved entry mut value: {any}\n", .{value});

    var entries = slot.entriesMut();
    std.debug.print("Entries length: {}\n", .{entries.len});
    for (entries, 0..) |e, idx| {
        std.debug.print("\tEntry {}: offset {}, length {} ", .{ idx, e.offset.get(), e.length.get() });
        std.debug.print("{any}\n", .{try slot.get(idx)});
    }

    try slot.remove(0);
    try slot.remove(4);
    try slot.remove(3);

    entries = slot.entriesMut();
    std.debug.print("Entries length: {}\n", .{entries.len});
    for (entries, 0..) |e, idx| {
        std.debug.print("\tEntry {}: offset {}, length {} ", .{ idx, e.offset.get(), e.length.get() });
        std.debug.print("{any}\n", .{try slot.get(idx)});
    }

    std.debug.print("Available space: {} : {}\n", .{ slot.availableSpace(), try slot.availableAfterCompact() });
    try slot.compactInPlace();
    std.debug.print("Available space after compact: {}\n", .{slot.availableSpace()});

    entries = slot.entriesMut();
    std.debug.print("Entries length: {}\n", .{entries.len});
    for (entries, 0..) |e, idx| {
        std.debug.print("\tEntry {}: offset {}, length {} ", .{ idx, e.offset.get(), e.length.get() });
        std.debug.print("{any}\n", .{try slot.get(idx)});
    }
}
