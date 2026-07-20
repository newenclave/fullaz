const std = @import("std");
const models_iface = @import("models/interfaces.zig");
const strategy_mod = @import("strategy.zig");
const flush_policy_mod = @import("flush_policy.zig");
const merge_cursor_mod = @import("merge_cursor.zig");
const value = @import("value.zig");
const Entry = @import("models/entry.zig").Entry;

pub fn Lsm(comptime ModelT: type, comptime StrategyFactory: fn (type) type, comptime FlushPolicyT: type) type {
    comptime models_iface.assertModel(ModelT);
    const Strategy = StrategyFactory(ModelT.RunIdType);
    comptime strategy_mod.assertCompactionStrategy(Strategy, ModelT.RunIdType);
    comptime flush_policy_mod.assertFlushPolicy(FlushPolicyT);

    const EngineError = ModelT.Error ||
        ModelT.MemtableType.Error ||
        Strategy.Error ||
        std.mem.Allocator.Error;

    const MergeCursor = merge_cursor_mod.MergeCursor(ModelT.RunType.Iterator);

    const Winner = enum {
        memtable,
        runs,
        none,
    };

    const IteratorImpl = struct {
        const IterSelf = @This();
        pub const Error = EngineError;

        mt_it: ModelT.MemtableType.Iterator,
        merged: MergeCursor,
        runs: []ModelT.RunType,
        cursors: []ModelT.RunType.Iterator,
        allocator: std.mem.Allocator,
        acc: *ModelT.AccessorType,
        winner: Winner,

        // choses the next winner and advances the other cursor if they are equal
        fn normalize(self: *IterSelf) Error!void {
            while (true) {
                const mt_entry = try self.mt_it.peek();
                const run_entry = try self.merged.peek();

                if (mt_entry == null and run_entry == null) {
                    self.winner = .none;
                    return;
                }

                var mt_wins = true;
                if (mt_entry == null) {
                    mt_wins = false;
                } else if (run_entry != null and std.mem.order(u8, mt_entry.?.key, run_entry.?.key) == .gt) {
                    mt_wins = false;
                }

                const entry = if (mt_wins) mt_entry.? else run_entry.?;

                if (mt_wins and run_entry != null and std.mem.eql(u8, entry.key, run_entry.?.key)) {
                    try self.merged.advance();
                }

                if (value.isTombstone(entry.value)) {
                    if (mt_wins) {
                        try self.mt_it.advance();
                    } else {
                        try self.merged.advance();
                    }
                    continue;
                }

                self.winner = if (mt_wins) .memtable else .runs;
                return;
            }
        }

        pub fn peek(self: *const IterSelf) Error!?Entry {
            return switch (self.winner) {
                .memtable => try self.mt_it.peek(),
                .runs => try self.merged.peek(),
                .none => null,
            };
        }

        pub fn advance(self: *IterSelf) Error!void {
            switch (self.winner) {
                .memtable => try self.mt_it.advance(),
                .runs => try self.merged.advance(),
                .none => return,
            }
            try self.normalize();
        }

        pub fn deinit(self: *IterSelf) void {
            self.mt_it.deinit();
            self.merged.deinit();
            for (self.runs) |*r| {
                self.acc.closeRun(r.*);
            }
            self.allocator.free(self.runs);
            self.allocator.free(self.cursors);
        }
    };

    return struct {
        const Self = @This();

        pub const Error = EngineError;

        pub const Model = ModelT;
        pub const Memtable = Model.MemtableType;
        pub const KeyInType = Model.KeyInType;
        pub const ValueInType = Model.ValueInType;
        pub const ValueOutType = Model.ValueOutType;
        pub const ValueEncodedType = Model.ValueEncodedType;
        pub const RunType = Model.RunType;
        pub const Iterator = IteratorImpl;

        model: *Model,
        allocator: std.mem.Allocator,
        flush_policy: FlushPolicyT,

        pub fn init(model: *Model, allocator: std.mem.Allocator, flush_policy: FlushPolicyT) Self {
            return .{
                .model = model,
                .allocator = allocator,
                .flush_policy = flush_policy,
            };
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn put(self: *Self, key: KeyInType, payload: ValueInType) Error!void {
            const acc = self.model.getAccessor();
            const buf = try self.allocator.alloc(u8, value.encodedLen(payload.len));
            defer self.allocator.free(buf);
            const enc = value.encodePut(buf, payload);

            {
                var active_table = acc.loadActiveMemtable();
                defer acc.deinitActiveMemtable(&active_table);
                try active_table.put(key, enc);
            }

            try self.maybeFlush();
        }

        pub fn delete(self: *Self, key: KeyInType) Error!void {
            const acc = self.model.getAccessor();

            var buf: [1]u8 = undefined;
            const enc = value.encodeTombstone(&buf);

            {
                var active_table = acc.loadActiveMemtable();
                defer acc.deinitActiveMemtable(&active_table);
                try active_table.put(key, enc);
            }

            try self.maybeFlush();
        }

        pub fn get(self: *Self, key: KeyInType) Error!?ValueOutType {
            const acc = self.model.getAccessor();
            var active_table = acc.loadActiveMemtable();
            defer acc.deinitActiveMemtable(&active_table);

            if (try active_table.get(key)) |enc| {
                return decode(enc);
            }

            const run_count = acc.runCount();
            var i: usize = 0;
            while (i < run_count) : (i += 1) {
                const run_id = acc.runIdAt(i);
                const run = (try acc.loadRun(run_id)) orelse {
                    continue;
                };
                defer acc.closeRun(run);

                if (try run.get(key)) |enc| {
                    return decode(enc);
                }
            }

            return null;
        }

        pub fn maybeFlush(self: *Self) Error!void {
            const acc = self.model.getAccessor();
            var active_table = acc.loadActiveMemtable();
            defer acc.deinitActiveMemtable(&active_table);

            if (self.flush_policy.shouldFlush(active_table.byteSize(), active_table.count())) {
                try self.flush();
            }
        }

        pub fn flush(self: *Self) Error!void {
            const acc = self.model.getAccessor();
            var active_table = acc.loadActiveMemtable();
            defer acc.deinitActiveMemtable(&active_table);

            if (active_table.count() == 0) {
                return;
            }

            var it = try active_table.iterator();
            const new_id = try acc.buildRun(&it);
            it.deinit();

            try active_table.reset();
            try acc.publish(&.{}, new_id);
            try self.compact();
        }

        // asks the Strategy what to merge next
        // TODO: think about move all allocations to accessor...
        // leave it for now like this.
        pub fn compact(self: *Self) Error!void {
            const acc = self.model.getAccessor();
            const run_count = acc.runCount();

            const RunInfo = strategy_mod.RunInfo(ModelT.RunIdType);

            const run_infos = try self.allocator.alloc(RunInfo, run_count);
            defer self.allocator.free(run_infos);

            var i: usize = 0;
            while (i < run_count) : (i += 1) {
                const run_id = acc.runIdAt(i);
                if (try acc.loadRun(run_id)) |*run| {
                    defer acc.closeRun(run.*);
                    run_infos[i] = .{
                        .id = run_id,
                        .byte_size = run.byteSize(),
                        .count = run.count(),
                    };
                }
            }

            const ids = try Strategy.planAfterFlush(self.allocator, run_infos);
            defer self.allocator.free(ids);

            if (ids.len < 2) {
                return;
            }

            var lo: usize = 0;
            while ((lo < run_infos.len) and (run_infos[lo].id != ids[0])) : (lo += 1) {}
            std.debug.assert(lo < run_infos.len);

            for (ids, 0..) |id, k| {
                std.debug.assert(run_infos[lo + k].id == id);
            }
            const reaches_oldest = (lo + ids.len == run_count);

            const runs = try self.allocator.alloc(RunType, ids.len);
            defer self.allocator.free(runs);
            var opened: usize = 0;
            defer {
                for (runs[0..opened]) |*r| {
                    acc.closeRun(r.*);
                }
            }

            const cursors = try self.allocator.alloc(RunType.Iterator, ids.len);
            defer self.allocator.free(cursors);

            for (ids, 0..) |id, k| {
                runs[k] = (try acc.loadRun(id)).?;
                opened = k + 1;
                cursors[k] = try runs[k].iterator();
            }

            var merged = try MergeCursor.init(cursors, reaches_oldest);
            defer merged.deinit();

            const new_id = try acc.buildRun(&merged);
            try acc.publish(ids, new_id);
        }

        pub fn iterator(self: *Self) Error!Iterator {
            const acc = self.model.getAccessor();
            var active_table = acc.loadActiveMemtable();
            defer acc.deinitActiveMemtable(&active_table);
            const mt_it = try active_table.iterator();

            return self.buildIterator(mt_it, null);
        }

        pub fn seek(self: *Self, key: KeyInType) Error!Iterator {
            const acc = self.model.getAccessor();
            var active_table = acc.loadActiveMemtable();
            defer acc.deinitActiveMemtable(&active_table);
            const mt_it = try active_table.seek(key);

            return self.buildIterator(mt_it, key);
        }

        fn buildIterator(self: *Self, mt_it: Memtable.Iterator, key: ?KeyInType) Error!Iterator {
            const acc = self.model.getAccessor();
            const run_count = acc.runCount();

            const runs = try self.allocator.alloc(RunType, run_count);
            errdefer self.allocator.free(runs);

            const cursors = try self.allocator.alloc(RunType.Iterator, run_count);
            errdefer self.allocator.free(cursors);

            var opened: usize = 0;
            errdefer {
                for (runs[0..opened]) |*r| {
                    acc.closeRun(r.*);
                }
            }

            var i: usize = 0;
            while (i < run_count) : (i += 1) {
                const run_id = acc.runIdAt(i);
                runs[i] = (try acc.loadRun(run_id)).?;
                opened = i + 1;
                cursors[i] = if (key) |k| try runs[i].seek(k) else try runs[i].iterator();
            }

            var result = Iterator{
                .mt_it = mt_it,
                .merged = try MergeCursor.init(cursors, true),
                .runs = runs,
                .cursors = cursors,
                .allocator = self.allocator,
                .acc = acc,
                .winner = .none,
            };
            try result.normalize();
            return result;
        }

        fn decode(enc: ValueEncodedType) ?ValueOutType {
            if (value.isTombstone(enc)) {
                return null;
            }
            return value.payloadOf(enc);
        }
    };
}
