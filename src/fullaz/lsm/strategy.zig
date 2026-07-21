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

// strategy should return a list. It's for now.
// TODO: needs to be fixed and moved to accessor?
// the caller is responsible for freeing the list.
//
// the returned ids may be any subset of runs (any combination, any order --
// MergeCursor's tie-break is lsn-based, not position-based, and engine.compact()
// opens each returned id directly rather than assuming a contiguous span).
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

        // Groups every run by tier, regardless of position, and returns the
        // largest tier group (ids in their original relative order) once it
        // reaches min_tier_runs. No adjacency requirement: a different-tier
        // run sitting between two same-tier runs no longer blocks them from
        // being merged together.
        pub fn planAfterFlush(allocator: std.mem.Allocator, runs: []const RunInfo(RunIdType)) Error![]RunIdType {
            var best_tier: usize = 0;
            var best_count: usize = 0;

            for (runs) |r| {
                const tier = tierOf(r.byte_size);
                var count: usize = 0;
                for (runs) |r2| {
                    if (tierOf(r2.byte_size) == tier) {
                        count += 1;
                    }
                }
                if (count > best_count) {
                    best_count = count;
                    best_tier = tier;
                }
            }

            if (best_count < min_tier_runs) {
                return &.{};
            }

            const ids = try allocator.alloc(RunIdType, best_count);
            var k: usize = 0;
            for (runs) |r| {
                if (tierOf(r.byte_size) == best_tier) {
                    ids[k] = r.id;
                    k += 1;
                }
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
