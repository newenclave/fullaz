const std = @import("std");
const packed_int = @import("../core/packed_int.zig");

// Encoded value = [tag:u8][payload]. Caller owns buf; needs >= payload.len + 1.
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

        pub fn encodedLen_(payload_len: usize) usize {
            return payload_len + @sizeOf(Header);
        }

        pub fn encodePut_(buf: []u8, payload: []const u8, lsn: LsnT) []const u8 {
            std.debug.assert(buf.len >= encodedLen_(payload.len));
            var header: *Header = @ptrCast(buf.ptr);
            header.tag = @intFromEnum(Tag.put);
            header.lsn.set(lsn);
            const body_offset = @sizeOf(Header);
            const body = buf[body_offset .. body_offset + payload.len];
            @memcpy(body, payload);
            return buf[0 .. body_offset + payload.len];
        }

        pub fn encodeTombstone_(buf: []u8, lsn: LsnT) []const u8 {
            std.debug.assert(buf.len >= @sizeOf(Header));
            var header: *Header = @ptrCast(buf.ptr);
            header.tag = @intFromEnum(Tag.tombstone);
            header.lsn.set(lsn);
            return buf[0..@sizeOf(Header)];
        }

        pub fn tagOf_(enc: []const u8) Tag {
            const header: *const Header = @ptrCast(enc.ptr);
            return @enumFromInt(header.tag);
        }

        pub fn payloadOf_(enc: []const u8) []const u8 {
            return enc[bodyOffset()..];
        }

        pub fn isTombstone_(enc: []const u8) bool {
            return tagOf_(enc) == .tombstone;
        }

        fn bodyOffset() usize {
            return @sizeOf(Header);
        }
    };
}

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
