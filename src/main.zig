const std = @import("std");
const fullaz = @import("root.zig");

// sandbox main function
//here I'm going to test some code snippets
pub fn main() !void {
    const Variadic = fullaz.slots.Variadic;
    var buffer = [_]u8{0} ** 1024;
    var slot = try Variadic(u32, .little, false).init(&buffer);
    slot.formatHeader();
    std.debug.print("Variadic slot initialized with body size: {}\n", .{slot.body.len});
    std.debug.print("Header entry count: {}\n", .{slot.headerConst().entry_count.get()});
    std.debug.print("Available space: {}\n", .{slot.availableSpace()});
    std.debug.print("Can insert 100 bytes: {}\n", .{slot.canInsert(100)});
    std.debug.print("Can insert 2000 bytes: {}\n", .{slot.canInsert(2000)});

    const entry = try slot.insert(&[_]u8{ 0, 1, 2, 3, 4, 5 });
    _ = try slot.insertAt(0, &[_]u8{ 0, 4, 3, 2, 1, 0, 1, 2, 3, 4, 5 });

    std.debug.print("Inserted entry at offset: {}, length: {}\n", .{ entry.offset.get(), entry.length.get() });

    if (try slot.getConstValue(0)) |value| {
        std.debug.print("Retrieved 0 entry value: {any}\n", .{value});
    }

    if (try slot.getConstValue(1)) |value| {
        std.debug.print("Retrieved entry value: {any}\n", .{value});
    }

    if (try slot.getMutValue(1)) |value| {
        std.debug.print("Retrieved entry mut value: {any}\n", .{value});
    }

    const entries = slot.entriesMut();
    std.debug.print("Entries length: {}\n", .{entries.len});
    for (entries, 0..) |e, idx| {
        std.debug.print("\tEntry {}: offset {}, length {}\n", .{ idx, e.offset.get(), e.length.get() });
    }
}
