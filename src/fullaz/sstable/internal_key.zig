const std = @import("std");
const PackedInt = @import("../core/packed_int.zig").PackedInt;

pub fn InternalKey(comptime Format: type, comptime cmp: anytype, comptime CtxT: type) type {
    const PackedLsn = PackedInt(Format.Lsn, Format.Endian);
    return struct {
        pub fn encode(key: []const u8, lsn: Format.Lsn, output: []u8) []const u8 {
            if (!Format.versioned_keys) {
                return key;
            }
            std.mem.copyForwards(u8, output[0..key.len], key);
            const packed_lsn = PackedLsn.init(lsn);
            @memcpy(output[key.len..][0..@sizeOf(PackedLsn)], &packed_lsn.bytes);
            return output[0 .. key.len + @sizeOf(PackedLsn)];
        }

        pub fn userKey(key: []const u8) error{BadData}![]const u8 {
            if (!Format.versioned_keys) {
                return key;
            }
            if (key.len < @sizeOf(PackedLsn)) {
                return error.BadData;
            }
            return key[0 .. key.len - @sizeOf(PackedLsn)];
        }

        pub fn sequence(key: []const u8) error{BadData}!Format.Lsn {
            if (key.len < @sizeOf(PackedLsn)) {
                return error.BadData;
            }
            const packed_lsn = PackedLsn.fromSlice(key[key.len - @sizeOf(PackedLsn) ..]) catch {
                return error.BadData;
            };
            return packed_lsn.get();
        }

        pub fn compare(ctx: CtxT, a: []const u8, b: []const u8) std.math.Order {
            if (!Format.versioned_keys) {
                return cmp(ctx, a, b);
            }
            if (a.len < @sizeOf(PackedLsn)) {
                return if (b.len < @sizeOf(PackedLsn)) std.mem.order(u8, a, b) else .lt;
            }
            if (b.len < @sizeOf(PackedLsn)) {
                return .gt;
            }
            const a_key = userKey(a) catch unreachable;
            const b_key = userKey(b) catch unreachable;
            const order = cmp(ctx, a_key, b_key);
            if (order != .eq) {
                return order;
            }
            return std.math.order(sequence(b) catch unreachable, sequence(a) catch unreachable);
        }
    };
}
