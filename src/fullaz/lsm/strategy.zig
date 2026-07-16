const std = @import("std");
const iface = @import("../contracts/interfaces.zig");

// One run's bookkeeping, as handed to a compaction strategy.
pub fn RunInfo(comptime RunIdType: type) type {
    return struct {
        id: RunIdType,
        byte_size: usize,
        count: usize,
    };
}

// strategy should return a list.
// the caller is responsible for freeing the list.
pub fn assertCompactionStrategy(comptime Strategy: type, comptime RunIdType: type) void {
    iface.requiresErrorDeclaration(Strategy, "Error");
    iface.requiresFnSignature(
        Strategy,
        "planAfterFlush",
        fn (std.mem.Allocator, []const RunInfo(RunIdType)) Strategy.Error![]RunIdType,
    );
}

// Always merges every existing run into one.
pub fn NaiveMergeAllStrategy(comptime RunIdType: type) type {
    return struct {
        pub const Error = std.mem.Allocator.Error;

        pub fn planAfterFlush(allocator: std.mem.Allocator, runs: []const RunInfo(RunIdType)) Error![]RunIdType {
            if (runs.len < 2) {
                return &.{};
            }
            const ids = try allocator.alloc(RunIdType, runs.len);
            for (runs, 0..) |r, i| {
                ids[i] = r.id;
            }
            return ids;
        }
    };
}

pub fn SizeTieredStrategy(comptime RunIdType: type) type {
    return struct {
        pub const Error = std.mem.Allocator.Error;

        pub const growth_factor: usize = 4;
        pub const min_tier_runs: usize = 4;

        pub fn planAfterFlush(allocator: std.mem.Allocator, runs: []const RunInfo(RunIdType)) Error![]RunIdType {
            var best_start: usize = 0;
            var best_len: usize = 0;

            var i: usize = 0;
            while (i < runs.len) {
                const tier = tierOf(runs[i].byte_size);
                var j = i + 1;
                while (j < runs.len and tierOf(runs[j].byte_size) == tier) {
                    j += 1;
                }

                const len = j - i;
                if (len > best_len) {
                    best_len = len;
                    best_start = i;
                }
                i = j;
            }

            if (best_len < min_tier_runs) {
                return &.{};
            }

            const ids = try allocator.alloc(RunIdType, best_len);
            for (runs[best_start .. best_start + best_len], 0..) |r, k| {
                ids[k] = r.id;
            }
            return ids;
        }

        fn tierOf(byte_size: usize) usize {
            if (byte_size == 0) {
                return 0;
            }
            var size = byte_size;
            var tier: usize = 0;
            while (size >= growth_factor) {
                size /= growth_factor;
                tier += 1;
            }
            return tier;
        }
    };
}
