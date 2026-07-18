const std = @import("std");
const models_iface = @import("models/interfaces.zig");
const strategy_mod = @import("strategy.zig");
const flush_policy_mod = @import("flush_policy.zig");
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
        pub const Memtable = ModelT.MemtableType;
        pub const KeyInType = ModelT.KeyInType;
        pub const ValueInType = ModelT.ValueInType;
        pub const ValueOutType = ModelT.ValueOutType;
        pub const ValueEncodedType = ModelT.ValueEncodedType;

        model: *ModelT,
        allocator: std.mem.Allocator,
        flush_policy: FlushPolicyT,

        pub fn init(model: *ModelT, allocator: std.mem.Allocator, flush_policy: FlushPolicyT) Self {
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

            var active_table = acc.loadActiveMemtable();
            defer acc.deinitActiveMemtable(&active_table);
            try active_table.put(key, enc);
        }

        pub fn delete(self: *Self, key: KeyInType) Error!void {
            const acc = self.model.getAccessor();

            var buf: [1]u8 = undefined;
            const enc = value.encodeTombstone(&buf);

            var active_table = acc.loadActiveMemtable();
            defer acc.deinitActiveMemtable(&active_table);
            try active_table.put(key, enc);
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
        }

        fn decode(enc: ValueEncodedType) ?ValueOutType {
            if (value.isTombstone(enc)) {
                return null;
            }
            return value.payloadOf(enc);
        }
    };
}
