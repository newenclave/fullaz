const std = @import("std");
const entry_mod = @import("models/entry.zig");
const value = @import("value.zig");
const algorithm = @import("../core/algorithm.zig");

fn keyOrder(_: void, a: []const u8, b: []const u8) !algorithm.Order {
    return algorithm.cmpSlices(u8, a, b, algorithm.CmpNum(u8).asc, {});
}

// a part of Merge Sort.
// choose the best candidate from a set of sorted sources, and skip duplicates.
// on a tied key the source with the larger lsn wins -- cursors may be
// passed in any order.
// it doesn't own the cursors
pub fn MergeCursorImpl(comptime CursorT: type, comptime keyCmp: anytype, comptime CmpCtx: type) type {
    const LsnT = CursorT.LsnType;
    const Entry = entry_mod.Entry(LsnT);

    return struct {
        const Self = @This();

        pub const Error = CursorT.Error;
        pub const LsnType = LsnT;

        cursors: []CursorT,
        drop_tombstones: bool,
        winner: ?usize,
        cmp_ctx: CmpCtx,

        pub fn init(cursors: []CursorT, drop_tombstones: bool) Error!Self {
            if (CmpCtx != void) {
                @compileError("MergeCursorImpl: a non-void context requires initWithContext");
            }
            return initWithContext(cursors, drop_tombstones, {});
        }

        pub fn initWithContext(cursors: []CursorT, drop_tombstones: bool, cmp_ctx: CmpCtx) Error!Self {
            var self = Self{
                .cursors = cursors,
                .drop_tombstones = drop_tombstones,
                .winner = null,
                .cmp_ctx = cmp_ctx,
            };
            try self.normalize();
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn peek(self: *const Self) Error!?Entry {
            const idx = self.winner orelse {
                return null;
            };
            return try self.cursors[idx].peek();
        }

        pub fn advance(self: *Self) Error!void {
            const idx = self.winner orelse {
                return;
            };
            const entry = (try self.cursors[idx].peek()).?;
            try self.skipKeyAcrossAll(entry.key);
            try self.normalize();
        }

        // find a new best candidate.
        // we do not start from the begginning of the cursors,
        // because the cursors change after c.advance()
        //
        fn normalize(self: *Self) Error!void {
            while (true) {
                var best: ?usize = null;
                var best_key: []const u8 = undefined;
                var best_lsn: LsnT = undefined;

                for (self.cursors, 0..) |*c, i| {
                    const e = (try c.peek()) orelse continue;
                    if (best == null) {
                        best = i;
                        best_key = e.key;
                        best_lsn = e.lsn;
                        continue;
                    }
                    const order = try keyCmp(self.cmp_ctx, e.key, best_key);
                    if (order == .lt or (order == .eq and e.lsn > best_lsn)) {
                        best = i;
                        best_key = e.key;
                        best_lsn = e.lsn;
                    }
                }

                const idx = best orelse {
                    self.winner = null;
                    return;
                };
                const entry = (try self.cursors[idx].peek()).?;

                if (self.drop_tombstones and value.isTombstone(entry.value)) {
                    try self.skipKeyAcrossAll(entry.key);
                    continue;
                }

                self.winner = idx;
                return;
            }
        }

        // advance() all the cursors with keys equal to the given key
        // basically we skip dupliccates here.
        fn skipKeyAcrossAll(self: *Self, key: []const u8) Error!void {
            for (self.cursors) |*c| {
                while (try c.peek()) |e| {
                    if (try keyCmp(self.cmp_ctx, e.key, key) != .eq) {
                        break;
                    }
                    try c.advance();
                }
            }
        }
    };
}

pub fn MergeCursor(comptime CursorT: type) type {
    return MergeCursorImpl(CursorT, keyOrder, void);
}
