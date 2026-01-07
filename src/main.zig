const std = @import("std");
const fullaz = @import("root.zig");

// sandbox main function
//here I'm going to test some code snippets

pub fn main() !void {
    const Variadic = fullaz.slots.Variadic;
    var buf1: [48]u8 = undefined; // Small buffer
    var buf2: [256]u8 = undefined;

    var slots1 = try Variadic(u16, .little, false).init(&buf1);
    var slots2 = try Variadic(u16, .little, false).init(&buf2);
    slots1.formatHeader();
    slots2.formatHeader();

    // Fill slots1 almost completely
    _ = try slots1.insert("abcdefgh");

    // slots2 has too much data
    _ = try slots2.insert("12345678901234567890");

    const status = try slots1.canMergeWith(&slots2);
    try std.testing.expectEqual(.not_enough, status);
}
