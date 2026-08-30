const std = @import("std");
const fullaz = @import("fullaz");

test "CowPaged keeps old snapshots while remapping a VID" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Cache = fullaz.storage.page_cache.PageCache(Device);
    const Map = fullaz.storage.virtual_page_map.CowPaged(Cache, u32);

    var device = try Device.init(std.testing.allocator, 512);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 16);
    defer cache.deinit();
    var map = try Map.init(&cache, .{
        .root_page_id = null,
        .root_level = 0,
        .next_virtual_page_id = 0,
    }, {});
    defer map.deinit();

    var first_cache_batch = try cache.begin();
    var first_map_batch = try map.begin();
    var first_data = try cache.create();
    const first_page_id = try first_data.pid();
    first_data.deinit();
    const virtual_page_id = try map.set(first_page_id);
    const first_snapshot = map.currentSnapshot();
    first_map_batch.commit();
    try first_cache_batch.commit();

    try std.testing.expectEqual(first_page_id, try map.get(virtual_page_id));

    var second_cache_batch = try cache.begin();
    var second_map_batch = try map.begin();
    var second_data = try cache.create();
    const second_page_id = try second_data.pid();
    second_data.deinit();
    try map.remap(virtual_page_id, second_page_id);
    const second_snapshot = map.currentSnapshot();
    second_map_batch.commit();
    try second_cache_batch.commit();

    try std.testing.expectEqual(second_page_id, try map.get(virtual_page_id));
    try std.testing.expect(first_snapshot.root_page_id.? != second_snapshot.root_page_id.?);

    var old_map = try Map.init(&cache, first_snapshot, {});
    defer old_map.deinit();
    try std.testing.expectEqual(first_page_id, try old_map.get(virtual_page_id));
}

test "CowPaged restores its snapshot before an append-only rollback" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Cache = fullaz.storage.page_cache.PageCache(Device);
    const Map = fullaz.storage.virtual_page_map.CowPaged(Cache, u32);

    var device = try Device.init(std.testing.allocator, 512);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 16);
    defer cache.deinit();
    var map = try Map.init(&cache, .{
        .root_page_id = null,
        .root_level = 0,
        .next_virtual_page_id = 0,
    }, {});
    defer map.deinit();

    var cache_batch = try cache.begin();
    var map_batch = try map.begin();
    var data = try cache.create();
    const page_id = try data.pid();
    data.deinit();
    const virtual_page_id = try map.set(page_id);
    map_batch.commit();
    try cache_batch.commit();

    const committed = map.currentSnapshot();
    const committed_page_count = cache.pageCount();
    var rollback_cache_batch = try cache.begin();
    var rollback_map_batch = try map.begin();
    var replacement = try cache.create();
    const replacement_page_id = try replacement.pid();
    replacement.deinit();
    try map.remap(virtual_page_id, replacement_page_id);
    rollback_map_batch.discard();
    try rollback_cache_batch.discard();

    try std.testing.expectEqualDeep(committed, map.currentSnapshot());
    try std.testing.expectEqual(committed_page_count, cache.pageCount());
    try std.testing.expectEqual(page_id, try map.get(virtual_page_id));
}

test "CowPaged mutates transaction-private nodes without another fork" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Cache = fullaz.storage.page_cache.PageCache(Device);
    const Map = fullaz.storage.virtual_page_map.CowPaged(Cache, u32);

    var device = try Device.init(std.testing.allocator, 512);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 16);
    defer cache.deinit();
    var map = try Map.init(&cache, .{
        .root_page_id = null,
        .root_level = 0,
        .next_virtual_page_id = 0,
    }, {});
    defer map.deinit();

    var cache_batch = try cache.begin();
    var map_batch = try map.begin();
    var first_data = try cache.create();
    const first_page_id = try first_data.pid();
    first_data.deinit();
    const first_virtual_page_id = try map.set(first_page_id);
    var second_data = try cache.create();
    const second_page_id = try second_data.pid();
    second_data.deinit();
    const second_virtual_page_id = try map.set(second_page_id);

    // Two data pages plus one shared, transaction-private mapping leaf.
    try std.testing.expectEqual(@as(usize, 3), cache.pageCount());
    try std.testing.expectEqual(first_page_id, try map.get(first_virtual_page_id));
    try std.testing.expectEqual(second_page_id, try map.get(second_virtual_page_id));
    map_batch.commit();
    try cache_batch.commit();
}
