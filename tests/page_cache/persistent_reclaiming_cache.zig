const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

fn Store(comptime PageIdT: type) type {
    const FreeListState = fullaz.storage.free_list.State(PageIdT, .little);
    return struct {
        const Self = @This();

        pub const PageId = PageIdT;
        pub const Error = error{ StateUnavailable, ReadOnly };
        pub const StateLeaseType = struct {
            pub const Error = Self.Error;

            store: *Self,

            pub fn data(self: *const @This()) @This().Error![]const u8 {
                return std.mem.asBytes(@as(*const FreeListState, &self.store.state_value));
            }

            pub fn dataMut(self: *@This()) @This().Error![]u8 {
                if (self.store.read_only) {
                    return error.ReadOnly;
                }
                return std.mem.asBytes(&self.store.state_value);
            }

            pub fn finish(self: *@This()) void {
                self.store.finish_count += 1;
            }

            pub fn deinit(self: *@This()) void {
                self.store.deinit_count += 1;
            }
        };

        state_value: FreeListState = .{},
        page_count: usize = 0,
        fail_acquire: bool = false,
        read_only: bool = false,
        finish_count: usize = 0,
        deinit_count: usize = 0,

        pub fn state(self: *Self) Error!StateLeaseType {
            if (self.fail_acquire) {
                return error.StateUnavailable;
            }
            return .{ .store = self };
        }

        pub fn pageCount(self: *const Self) usize {
            return self.page_count;
        }

        pub fn isReserved(_: *const Self, _: PageId) bool {
            return false;
        }
    };
}

test "Pages: persistent reclaiming cache reuses and rolls back free-list roots" {
    const Device = fullaz.device.MemoryBlock(u32);
    const InnerCache = fullaz.storage.page_cache.PageCache(Device);
    const StoreT = Store(u32);
    const Cache = fullaz_db.PersistentReclaimingCache(InnerCache, StoreT);

    var device = try Device.init(std.testing.allocator, 256);
    defer device.deinit();
    var inner = try InnerCache.init(&device, std.testing.allocator, 4);
    defer inner.deinit();
    var store = StoreT{};
    var cache = Cache.init(&inner, &store);
    defer cache.deinit();

    var first = try cache.create();
    const first_id = try first.pid();
    first.deinit();
    var second = try cache.create();
    const second_id = try second.pid();
    second.deinit();
    store.page_count = device.blocksCount();

    try cache.free(first_id);
    try cache.free(second_id);
    try std.testing.expectEqual(second_id, store.state_value.root.get());

    var transaction = try cache.begin();
    var reused = try cache.create();
    try std.testing.expectEqual(second_id, try reused.pid());
    reused.deinit();
    try transaction.discard();
    try std.testing.expectEqual(second_id, store.state_value.root.get());

    var reused_after_rollback = try cache.create();
    defer reused_after_rollback.deinit();
    try std.testing.expectEqual(second_id, try reused_after_rollback.pid());
    try std.testing.expectEqual(@as(usize, 5), store.finish_count);
}

test "Pages: persistent reclaiming cache reserves the free-list sentinel PID" {
    const Device = fullaz.device.MemoryBlock(u8);
    const InnerCache = fullaz.storage.page_cache.PageCache(Device);
    const StoreT = Store(u8);
    const Cache = fullaz_db.PersistentReclaimingCache(InnerCache, StoreT);
    var device = try Device.init(std.testing.allocator, 32);
    defer device.deinit();
    var inner = try InnerCache.init(&device, std.testing.allocator, 4);
    defer inner.deinit();
    var store = StoreT{};
    var cache = Cache.init(&inner, &store);
    defer cache.deinit();

    for (0..std.math.maxInt(u8)) |_| {
        var page = try cache.create();
        page.deinit();
        store.page_count = device.blocksCount();
    }
    try std.testing.expectError(error.PageIdExhausted, cache.create());
    try std.testing.expectEqual(@as(usize, std.math.maxInt(u8)), device.blocksCount());
}

test "Pages: persistent reclaiming cache rejects an out-of-range free root before mutation" {
    const Device = fullaz.device.MemoryBlock(u32);
    const InnerCache = fullaz.storage.page_cache.PageCache(Device);
    const StoreT = Store(u32);
    const Cache = fullaz_db.PersistentReclaimingCache(InnerCache, StoreT);

    var device = try Device.init(std.testing.allocator, 256);
    defer device.deinit();
    var inner = try InnerCache.init(&device, std.testing.allocator, 4);
    defer inner.deinit();
    var page = try inner.create();
    page.deinit();
    var store = StoreT{};
    store.state_value.root.set(99);
    var cache = Cache.init(&inner, &store);
    defer cache.deinit();

    try std.testing.expectError(error.BadFreeList, cache.create());
    try std.testing.expectEqual(@as(u32, 99), store.state_value.root.get());
}

test "Pages: persistent reclaiming cache restores page zero as the exact state" {
    const Device = fullaz.device.MemoryBlock(u32);
    const InnerCache = fullaz.storage.page_cache.PageCache(Device);
    const StoreT = Store(u32);
    const Cache = fullaz_db.PersistentReclaimingCache(InnerCache, StoreT);

    var device = try Device.init(std.testing.allocator, 256);
    defer device.deinit();
    var inner = try InnerCache.init(&device, std.testing.allocator, 2);
    defer inner.deinit();
    var store = StoreT{};
    var cache = Cache.init(&inner, &store);
    defer cache.deinit();

    var page = try cache.create();
    page.deinit();
    store.page_count = device.blocksCount();
    try cache.free(0);
    const snapshot = store.state_value;

    var batch = try cache.begin();
    var reused = try cache.create();
    reused.deinit();
    try std.testing.expect(store.state_value.root.isMax());
    try batch.discard();

    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&snapshot),
        std.mem.asBytes(&store.state_value),
    );
    try std.testing.expectEqual(@as(u32, 0), store.state_value.root.get());
    try std.testing.expectEqual(@as(usize, 3), store.finish_count);
}

test "Pages: persistent reclaiming cache handles failed and read-only state acquisition" {
    const Device = fullaz.device.MemoryBlock(u32);
    const InnerCache = fullaz.storage.page_cache.PageCache(Device);
    const StoreT = Store(u32);
    const Cache = fullaz_db.PersistentReclaimingCache(InnerCache, StoreT);

    var device = try Device.init(std.testing.allocator, 256);
    defer device.deinit();
    var inner = try InnerCache.init(&device, std.testing.allocator, 2);
    defer inner.deinit();
    var store = StoreT{};
    var cache = Cache.init(&inner, &store);
    defer cache.deinit();

    store.fail_acquire = true;
    try std.testing.expectError(error.StateUnavailable, cache.begin());
    try std.testing.expect(!inner.transactionActive());

    store.fail_acquire = false;
    var page = try cache.create();
    page.deinit();
    store.page_count = device.blocksCount();
    store.read_only = true;
    try std.testing.expectError(error.ReadOnly, cache.free(0));
    try std.testing.expect(store.state_value.root.isMax());
    try std.testing.expectEqual(@as(usize, 0), store.finish_count);
    try std.testing.expect(store.deinit_count > 0);
}
