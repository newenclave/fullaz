const std = @import("std");

// Encoded value = [tag:u8][payload]. Caller owns buf; needs >= payload.len + 1.
pub const Tag = enum(u8) {
    put = 0,
    tombstone = 1,
};

pub fn encodedLen(payload_len: usize) usize {
    return payload_len + 1;
}

pub fn encodePut(buf: []u8, payload: []const u8) []const u8 {
    std.debug.assert(buf.len >= payload.len + 1);
    buf[0] = @intFromEnum(Tag.put);
    @memcpy(buf[1 .. 1 + payload.len], payload);
    return buf[0 .. 1 + payload.len];
}

pub fn encodeTombstone(buf: []u8) []const u8 {
    std.debug.assert(buf.len >= 1);
    buf[0] = @intFromEnum(Tag.tombstone);
    return buf[0..1];
}

pub fn tagOf(enc: []const u8) Tag {
    return @enumFromInt(enc[0]);
}

pub fn payloadOf(enc: []const u8) []const u8 {
    return enc[1..];
}

pub fn isTombstone(enc: []const u8) bool {
    return tagOf(enc) == .tombstone;
}
