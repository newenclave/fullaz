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

pub fn assertCompactionStrategy(comptime Strategy: type, comptime RunIdType: type) void {
    iface.requiresErrorDeclaration(Strategy, "Error");
    iface.requiresFnSignature(
        Strategy,
        "planAfterFlush",
        fn (std.mem.Allocator, []const RunInfo(RunIdType)) Strategy.Error![]RunIdType,
    );
}

// simple strategy, that returns all the ids if runs.len >=2.
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
