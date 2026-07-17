const std = @import("std");
const interfaces = @import("interfaces.zig");
const core = @import("../../core/core.zig");
const value = @import("../value.zig");

pub fn MemoryModel(comptime MemtableT: type) type {
    comptime {
        interfaces.assertMemtable(MemtableT);
    }

    const Bloom = core.bloom.Bloom;
    const BloomWord = Bloom.HashType;

    const RunId = usize;
    const BloomBits = core.bitset.BitSet(BloomWord, .native);
    const target_false_positive_rate: f64 = 0.01;

    const StoredRun = struct {
        const Self = @This();

        table: MemtableT,
        bloom_buf: []u8,
        bloom_bits: BloomBits,
        bloom_k: usize,

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.table.deinit();
            allocator.free(self.bloom_buf);
        }
    };

    const Context = struct {
        allocator: std.mem.Allocator,
        active: MemtableT,
        run_table: std.ArrayList(?*StoredRun),
        run_order: std.ArrayList(RunId),
    };

    const RunImpl = struct {
        const Self = @This();

        stored: *const StoredRun,
        run_id: RunId,

        pub const Error = MemtableT.Error;
        pub const Iterator = MemtableT.Iterator;

        pub fn id(self: *const Self) RunId {
            return self.run_id;
        }

        pub fn byteSize(self: *const Self) usize {
            return self.stored.table.byteSize();
        }

        pub fn count(self: *const Self) usize {
            return self.stored.table.count();
        }

        pub fn get(self: *const Self, key: []const u8) Error!?[]const u8 {
            var bloom = Bloom.init();
            defer bloom.deinit();
            if (!bloom.mightContain(&self.stored.bloom_bits, key, self.stored.bloom_k)) {
                return null;
            }
            return self.stored.table.get(key);
        }

        pub fn iterator(self: *const Self) Error!Iterator {
            return self.stored.table.iterator();
        }

        pub fn seek(self: *const Self, key: []const u8) Error!Iterator {
            return self.stored.table.seek(key);
        }
    };

    const MemtableWrapper = struct {
        const Self = @This();

        pub const Error = MemtableT.Error;
        pub const Iterator = MemtableT.Iterator;

        pub const KeyInType = MemtableT.KeyInType;
        pub const ValueInType = MemtableT.ValueInType;
        pub const ValueOutType = MemtableT.ValueOutType;

        table: *MemtableT,

        pub fn init(table: *MemtableT) Self {
            return .{
                .table = table,
            };
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn reset(self: *Self) Error!void {
            return self.table.reset();
        }

        pub fn put(self: *Self, key: []const u8, value_in: []const u8) Error!void {
            return self.table.put(key, value_in);
        }

        pub fn get(self: *const Self, key: []const u8) Error!?[]const u8 {
            return self.table.get(key);
        }

        pub fn byteSize(self: *const Self) usize {
            return self.table.byteSize();
        }

        pub fn count(self: *const Self) usize {
            return self.table.count();
        }
        pub fn iterator(self: *const Self) Error!MemtableT.Iterator {
            return self.table.iterator();
        }

        pub fn seek(self: *const Self, key: []const u8) Error!MemtableT.Iterator {
            return self.table.seek(key);
        }
    };

    const AccessorImpl = struct {
        const Self = @This();

        pub const Error = MemtableT.Error ||
            std.mem.Allocator.Error ||
            BloomBits.Error;

        ctx: Context = undefined,

        pub fn init(allocator: std.mem.Allocator) Error!Self {
            return .{
                .ctx = .{
                    .allocator = allocator,
                    .active = try MemtableT.init(allocator),
                    .run_table = try std.ArrayList(?*StoredRun).initCapacity(allocator, 2),
                    .run_order = try std.ArrayList(RunId).initCapacity(allocator, 2),
                },
            };
        }

        pub fn deinit(self: *Self) void {
            self.ctx.active.deinit();
            for (self.ctx.run_table.items) |slot| {
                if (slot) |stored| {
                    stored.deinit(self.ctx.allocator);
                    self.ctx.allocator.destroy(stored);
                }
            }
            self.ctx.run_table.deinit(self.ctx.allocator);
            self.ctx.run_order.deinit(self.ctx.allocator);
        }

        pub fn loadActiveMemtable(self: *Self) MemtableWrapper {
            return MemtableWrapper.init(&self.ctx.active);
        }

        pub fn deinitActiveMemtable(self: *Self, t: *MemtableWrapper) void {
            _ = self;
            t.deinit();
        }

        pub fn runCount(self: *const Self) usize {
            return self.ctx.run_order.items.len;
        }

        pub fn runIdAt(self: *const Self, index: usize) RunId {
            return self.ctx.run_order.items[index];
        }

        pub fn loadRun(self: *Self, run_id: RunId) Error!?RunImpl {
            const slot = self.ctx.run_table.items[run_id] orelse {
                return null;
            };
            return RunImpl{
                .stored = slot,
                .run_id = run_id,
            };
        }

        pub fn closeRun(self: *Self, run: ?RunImpl) void {
            _ = self;
            _ = run;
        }

        pub fn buildRun(self: *Self, cursor: anytype) Error!RunId {
            const stored = try self.ctx.allocator.create(StoredRun);
            errdefer self.ctx.allocator.destroy(stored);

            stored.table = try MemtableT.init(self.ctx.allocator);
            errdefer stored.table.deinit();

            while (try cursor.peek()) |e| : (try cursor.advance()) {
                try stored.table.put(e.key, e.value);
            }

            var bloom = Bloom.init();
            defer bloom.deinit();
            const bloom_params = Bloom.calculateBloomParams(
                stored.table.count(),
                target_false_positive_rate,
            );
            stored.bloom_k = bloom_params.hash_count;
            stored.bloom_buf = try self.ctx.allocator.alloc(u8, bloom_params.bitset_words * @sizeOf(BloomWord));
            errdefer self.ctx.allocator.free(stored.bloom_buf);

            @memset(stored.bloom_buf, 0);

            stored.bloom_bits = try BloomBits.initMutable(stored.bloom_buf, bloom_params.bitset_bits);

            var it = try stored.table.iterator();
            defer it.deinit();

            while (try it.peek()) |e| : (try it.advance()) {
                bloom.add(&stored.bloom_bits, e.key, stored.bloom_k);
            }

            const run_id = self.ctx.run_table.items.len;
            try self.ctx.run_table.append(self.ctx.allocator, stored);
            return run_id;
        }

        pub fn publish(self: *Self, old_ids: []const RunId, new_id: ?RunId) Error!void {
            const at = if (old_ids.len == 0) 0 else self.positionOf(old_ids[0]).?;

            for (old_ids) |_| {
                _ = self.ctx.run_order.orderedRemove(at);
            }
            for (old_ids) |old_id| {
                self.destroyRunAt(old_id);
            }

            if (new_id) |id| {
                try self.ctx.run_order.insert(self.ctx.allocator, at, id);
            }
        }

        fn positionOf(self: *const Self, run_id: RunId) ?usize {
            for (self.ctx.run_order.items, 0..) |id, i| {
                if (id == run_id) {
                    return i;
                }
            }
            return null;
        }

        fn destroyRunAt(self: *Self, run_id: RunId) void {
            const slot = self.ctx.run_table.items[run_id] orelse {
                return;
            };
            slot.deinit(self.ctx.allocator);
            self.ctx.allocator.destroy(slot);
            self.ctx.run_table.items[run_id] = null;
        }
    };

    return struct {
        const Self = @This();

        pub const AccessorType = AccessorImpl;
        pub const RunType = RunImpl;

        pub const RunIdType = RunId;
        pub const Error = MemtableT.Error ||
            std.mem.Allocator.Error ||
            AccessorType.Error;
        pub const MemtableType = MemtableWrapper;

        pub const KeyInType = MemtableT.KeyInType;
        pub const ValueInType = MemtableT.ValueInType;
        pub const ValueOutType = MemtableT.ValueOutType;

        pub const ValueEncodedType = ValueInType;

        accessor: AccessorType,

        pub fn init(allocator: std.mem.Allocator) Error!Self {
            return Self{
                .accessor = try AccessorType.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.accessor.deinit();
            self.* = undefined;
        }

        pub fn getAccessor(self: *Self) *AccessorType {
            return &self.accessor;
        }
    };
}
