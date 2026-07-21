const std = @import("std");
const packed_int = @import("../core/packed_int.zig");

// Encoded value = [tag:u8][lsn:LsnT][payload]. Caller owns buf; needs >= payload.len + 1 + @sizeOf(LsnT).
pub const Tag = enum(u8) {
    put = 0,
    tombstone = 1,
};

pub fn Value(comptime LsnT: type, comptime endian: std.builtin.Endian) type {
    const LsnPacked = packed_int.PackedInt(LsnT, endian);

    const Header = extern struct {
        tag: u8,
        lsn: LsnPacked,
    };

    return struct {
        const Self = @This();
        pub const Lsn = LsnT;

        pub fn encodedLen(payload_len: usize) usize {
            return payload_len + @sizeOf(Header);
        }

        pub fn encodePut(buf: []u8, payload: []const u8, lsn: LsnT) []const u8 {
            std.debug.assert(buf.len >= Self.encodedLen(payload.len));
            var header: *Header = @ptrCast(buf.ptr);
            header.tag = @intFromEnum(Tag.put);
            header.lsn.set(lsn);
            const body_offset = @sizeOf(Header);
            const body = buf[body_offset .. body_offset + payload.len];
            @memcpy(body, payload);
            return buf[0 .. body_offset + payload.len];
        }

        pub fn encodeTombstone(buf: []u8, lsn: LsnT) []const u8 {
            std.debug.assert(buf.len >= @sizeOf(Header));
            var header: *Header = @ptrCast(buf.ptr);
            header.tag = @intFromEnum(Tag.tombstone);
            header.lsn.set(lsn);
            return buf[0..@sizeOf(Header)];
        }

        pub fn tagOf(enc: []const u8) Tag {
            const header: *const Header = @ptrCast(enc.ptr);
            return @enumFromInt(header.tag);
        }

        pub fn payloadOf(enc: []const u8) []const u8 {
            return enc[bodyOffset()..];
        }

        pub fn isTombstone(enc: []const u8) bool {
            return Self.tagOf(enc) == .tombstone;
        }

        pub fn lsnOf(enc: []const u8) LsnT {
            const header: *const Header = @ptrCast(enc.ptr);
            return header.lsn.get();
        }

        fn bodyOffset() usize {
            return @sizeOf(Header);
        }
    };
}

// tag is always the first byte
pub fn tagOf(enc: []const u8) Tag {
    return @enumFromInt(enc[0]);
}

pub fn isTombstone(enc: []const u8) bool {
    return tagOf(enc) == .tombstone;
}
