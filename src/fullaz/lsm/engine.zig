const std = @import("std");
const models_iface = @import("models/interfaces.zig");
const strategy_mod = @import("strategy.zig");
const flush_policy_mod = @import("flush_policy.zig");
const merge_cursor_mod = @import("merge_cursor.zig");
const value = @import("value.zig");

pub fn Lsm(comptime ModelT: type, comptime StrategyFactory: fn (type) type, comptime FlushPolicyT: type) type {
    comptime models_iface.assertModel(ModelT);
    const Strategy = StrategyFactory(ModelT.RunIdType);
    comptime strategy_mod.assertCompactionStrategy(Strategy, ModelT.RunIdType);
    comptime flush_policy_mod.assertFlushPolicy(FlushPolicyT);

    return struct {
        const Self = @This();

        pub const Error = ModelT.Error ||
            ModelT.MemtableType.Error ||
            Strategy.Error ||
            std.mem.Allocator.Error;

        pub const Model = ModelT;
        pub const Memtable = Model.MemtableType;
        pub const KeyInType = Model.KeyInType;
        pub const ValueInType = Model.ValueInType;
        pub const ValueOutType = Model.ValueOutType;
        pub const ValueEncodedType = Model.ValueEncodedType;
        pub const RunType = Model.RunType;

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

            const MergeCursor = merge_cursor_mod.MergeCursor(RunType.Iterator);

            var merged = try MergeCursor.init(cursors, reaches_oldest);
            defer merged.deinit();

            const new_id = try acc.buildRun(&merged);
            try acc.publish(ids, new_id);
        }

        fn decode(enc: ValueEncodedType) ?ValueOutType {
            if (value.isTombstone(enc)) {
                return null;
            }
            return value.payloadOf(enc);
        }
    };
}
