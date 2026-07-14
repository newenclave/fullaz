const std = @import("std");
const iface = @import("../contracts/interfaces.zig");

// Borrowed key/value pair. value is the encoded [tag][payload] blob (value.zig),
pub const Entry = struct {
    key: []const u8,
    value: []const u8,
};

pub fn assertKvCursor(comptime It: type) void {
    iface.requiresErrorDeclaration(It, "Error");
    const E = It.Error;
    iface.requiresFnSignature(It, "peek", fn (*const It) E!?Entry);
    iface.requiresFnSignature(It, "advance", fn (*It) E!void);
    iface.requiresFnSignature(It, "deinit", fn (*It) void);
}

pub fn assertMemtable(comptime M: type) void {
    iface.requiresErrorDeclaration(M, "Error");
    iface.requiresTypeDeclaration(M, "Iterator");

    const E = M.Error;
    const It = M.Iterator;

    iface.requiresFnSignature(M, "init", fn (std.mem.Allocator) E!M);
    iface.requiresFnSignature(M, "deinit", fn (*M) void);
    iface.requiresFnSignature(M, "reset", fn (*M) E!void);
    iface.requiresFnSignature(M, "put", fn (*M, []const u8, []const u8) E!void);
    iface.requiresFnSignature(M, "get", fn (*const M, []const u8) E!?[]const u8);
    iface.requiresFnSignature(M, "byteSize", fn (*const M) usize);
    iface.requiresFnSignature(M, "count", fn (*const M) usize);
    iface.requiresFnSignature(M, "iterator", fn (*const M) E!It);
    iface.requiresFnSignature(M, "seek", fn (*const M, []const u8) E!It);
    assertKvCursor(It);
}
