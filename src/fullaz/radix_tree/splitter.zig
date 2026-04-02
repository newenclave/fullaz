const std = @import("std");
const errors = @import("../core/errors.zig");

pub fn Splitter(comptime KeyT: type) type {
    const Key = KeyT;

    return struct {
        const Self = @This();

        pub const Error = errors.SpaceError;

        inode_base: KeyT = undefined,
        leaf_base: KeyT = undefined,
        maximum_levels: usize = 0,

        pub const Result = struct {
            digit: KeyT,
            quotient: KeyT,
            level: usize = 0,
        };

        pub fn init(inode_base: KeyT, leaf_base: KeyT) Self {
            return Self{
                .inode_base = inode_base,
                .leaf_base = leaf_base,
                .maximum_levels = Self.maxLevelsMixed(leaf_base, inode_base),
            };
        }

        pub fn split(self: *const Self, key: KeyT, tmp_buf: []Result) Error![]Result {
            if (tmp_buf.len < 1) {
                return Error.BufferTooSmall;
            }
            tmp_buf[0] = Result{
                .digit = key % self.leaf_base,
                .quotient = key / self.leaf_base,
                .level = 0,
            };

            var inode_key = key / self.leaf_base;
            var id: usize = 1;
            while (inode_key > 0) {
                if (id >= tmp_buf.len) {
                    return Error.BufferTooSmall;
                }
                tmp_buf[id] = Result{
                    .digit = inode_key % self.inode_base,
                    .quotient = inode_key / self.inode_base,
                    .level = id,
                };
                id += 1;
                inode_key /= self.inode_base;
            }
            return tmp_buf[0..id];
        }

        pub fn level(self: *const Self, key: KeyT) usize {
            var lvl: usize = 0;
            var inode_key = key / self.leaf_base;
            while (inode_key > 0) {
                lvl += 1;
                inode_key /= self.inode_base;
            }
            return lvl;
        }

        fn maxLevelsMixed(leaf_base: Key, inode_base: Key) usize {
            if (leaf_base < 2 or inode_base < 2) {
                @panic("bases must be >= 2");
            }

            const k_max: Key = std.math.maxInt(Key);

            if (k_max < leaf_base) {
                return 1;
            }

            var n: usize = 1;
            var cap: Key = leaf_base;

            while (cap <= k_max) : (n += 1) {
                if (cap > @divTrunc(k_max, inode_base)) {
                    return n + 1;
                }
                cap *= inode_base;
            }
            return n;
        }
    };
}
