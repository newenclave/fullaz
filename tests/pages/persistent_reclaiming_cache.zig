const std = @import("std");
const fullaz = @import("fullaz");

test "Pages: persistent reclaiming cache reuses and rolls back free-list roots" {
    const Device = fullaz.device.MemoryBlock(u32);
    const InnerCache = fullaz.storage.page_cache.PageCache(Device);
    const Store = struct {
        pub const PageId = u32;
        pub const Error = error{};

        root: ?PageId = null,
        page_count: usize = 0,

        pub fn getRoot(self: *const @This()) ?PageId {
            return self.root;
        }

        pub fn setRoot(self: *@This(), root: ?PageId) Error!void {
            self.root = root;
        }

        pub fn pageCount(self: *const @This()) usize {
            return self.page_count;
        }

        pub fn isReserved(_: *const @This(), _: PageId) bool {
            return false;
        }
    };
    const Cache = fullaz.pages.PersistentReclaimingCache(InnerCache, Store);

    var device = try Device.init(std.testing.allocator, 256);
    defer device.deinit();
    var inner = try InnerCache.init(&device, std.testing.allocator, 4);
    defer inner.deinit();
    var store = Store{};
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
    try std.testing.expectEqual(second_id, store.root.?);

    var transaction = try cache.begin();
    var reused = try cache.create();
    try std.testing.expectEqual(second_id, try reused.pid());
    reused.deinit();
    try transaction.discard();
    try std.testing.expectEqual(second_id, store.root.?);

    var reused_after_rollback = try cache.create();
    defer reused_after_rollback.deinit();
    try std.testing.expectEqual(second_id, try reused_after_rollback.pid());
}
