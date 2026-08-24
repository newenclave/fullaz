const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

const Device = fullaz.device.MemoryBlock(u32);
const RawCache = fullaz.storage.page_cache.PageCache(Device);
const Cache = fullaz_db.MemoryReclaimingCache(RawCache);
const Location = fullaz.page.slot_heap.SlotHeap(u32, u16, .little).Location;

const Backend = struct {
    pub const PageId = u32;
    pub const CacheType = Cache;

    cache_ptr: *Cache,

    pub fn cache(self: *@This()) *Cache {
        return self.cache_ptr;
    }
};

const Manager = fullaz_db.SlotHeapManager(
    Backend,
    Location,
    32,
    6,
);

fn compare(_: void, left: []const u8, right: []const u8) std.math.Order {
    return std.mem.order(u8, left, right);
}

const Descriptor = fullaz_db.slotHeap(.{
    .compare = compare,
    .CompareContext = void,
    .comparator_id = 1,
    .maximum_key_size = 4,
    .maximum_value_size = 16,
});

test "SlotHeap manager stores heap and FSM metadata together" {
    var device = try Device.init(std.testing.allocator, 256);
    defer device.deinit();
    var raw_cache = try RawCache.init(&device, std.testing.allocator, 2);
    defer raw_cache.deinit();
    var cache = Cache.init(std.testing.allocator, &raw_cache);
    defer cache.deinit();
    var backend = Backend{ .cache_ptr = &cache };
    var manager = Manager.init(&backend);

    try manager.setRoot(7);
    try manager.setCachedTop(.{ .page_id = 7, .slot_id = 0 });
    try manager.setEntriesCount(11);
    try manager.setAvailableInode(1, 8);
    try manager.setSizeClassRoot(2, 9);

    try std.testing.expectEqual(@as(?u32, 7), manager.getRoot());
    try std.testing.expectEqual(@as(?Location, .{ .page_id = 7, .slot_id = 0 }), manager.getCachedTop());
    try std.testing.expectEqual(@as(u64, 11), try manager.getEntriesCount());
    try std.testing.expectEqual(@as(?u32, 8), try manager.getAvailableInode(1));
    try std.testing.expectEqual(@as(?u32, 9), try manager.getSizeClassRoot(2));
    try std.testing.expectError(error.MaxDepth, manager.getAvailableInode(33));
    try std.testing.expectError(error.InvalidSizeClass, manager.getSizeClassRoot(6));
}

test "fullaz-db: SlotHeap descriptor composes its manager, FSM, and paged model" {
    const Binding = Descriptor.Trait.Binding(Backend);
    comptime fullaz_db.assertBinding(Binding, Backend);
    comptime fullaz_db.assertStaticMetadata(Binding, Binding.StaticMetadata);

    var device = try Device.init(std.testing.allocator, 256);
    defer device.deinit();
    var raw_cache = try RawCache.init(&device, std.testing.allocator, 8);
    defer raw_cache.deinit();
    var cache = Cache.init(std.testing.allocator, &raw_cache);
    defer cache.deinit();
    var backend = Backend{ .cache_ptr = &cache };
    var runtime: Binding.Runtime = undefined;
    try Binding.initRuntime(
        &runtime,
        &backend,
        .{ .base = 0x0100, .count = 3 },
        .{},
    );
    defer Binding.deinitRuntime(&runtime);

    try std.testing.expectEqual(@as(?u32, null), runtime.manager.getRoot());
    try std.testing.expectEqual(@as(u64, 0), try runtime.heap.count());

    var batch = try cache.begin();
    var proxy = Binding.proxy(&runtime);
    try proxy.push("0002", "two");
    try proxy.push("0001", "one");
    var top = try proxy.top();
    defer top.deinit();
    try std.testing.expectEqualSlices(u8, "0001", try top.key());
    try std.testing.expectEqualSlices(u8, "one", try top.value());
    top.deinit();
    try proxy.pop();
    try batch.commit();

    const read_proxy = Binding.proxyConst(&runtime);
    try std.testing.expectEqual(@as(u64, 1), try read_proxy.count());
}

test "fullaz-db: SlotHeap memory database commits and rolls back" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 })
        .add("heap", Descriptor);
    const Db = fullaz_db.MemoryDatabase(Schema);
    var database = try Db.init(std.testing.allocator, .{
        .page_size = 256,
        .cache_frames = 8,
    });
    defer database.deinit();

    {
        var transaction = try database.begin();
        defer transaction.deinit();
        try transaction.get("heap").push("0002", "two");
        try transaction.rollback();
    }
    try std.testing.expectEqual(@as(usize, 0), database.diagnostics().physical_page_count);

    {
        var transaction = try database.begin();
        defer transaction.deinit();
        try transaction.get("heap").push("0002", "two");
        try transaction.get("heap").push("0001", "one");
        try transaction.commit();
    }
    try std.testing.expectEqual(@as(u64, 2), try database.getConst("heap").count());
}
