const std = @import("std");
const fullaz = @import("fullaz");

test "Pages: memory reclaiming cache forwards basic page-cache operations" {
    const Device = fullaz.device.MemoryBlock(u32);
    const InnerCache = fullaz.storage.page_cache.PageCache(Device);
    const Cache = fullaz.pages.MemoryReclaimingCache(InnerCache);

    var device = try Device.init(std.testing.allocator, 256);
    defer device.deinit();
    var inner = try InnerCache.init(&device, std.testing.allocator, 2);
    defer inner.deinit();
    var cache = Cache.init(std.testing.allocator, &inner);
    defer cache.deinit();

    try std.testing.expectEqual(@as(usize, 256), cache.pageSize());
    var temporary = try cache.getTemporaryPage();
    temporary.deinit();

    var created = try cache.create();
    const page_id = try created.pid();
    created.deinit();
    try std.testing.expectEqual(@as(u32, 0), page_id);
    try std.testing.expectEqual(@as(usize, 1), cache.physical_page_count);
    try std.testing.expect(cache.free_pages.capacity >= cache.physical_page_count);

    var fetched = try cache.fetch(page_id);
    fetched.deinit();
    try cache.flush(page_id);
    try cache.flushAll();
}

test "Pages: memory reclaiming cache reserves free capacity before append" {
    const Device = fullaz.device.MemoryBlock(u32);
    const InnerCache = fullaz.storage.page_cache.PageCache(Device);
    const Cache = fullaz.pages.MemoryReclaimingCache(InnerCache);

    var device = try Device.init(std.testing.allocator, 256);
    defer device.deinit();
    var inner = try InnerCache.init(&device, std.testing.allocator, 2);
    defer inner.deinit();
    var empty_buffer: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&empty_buffer);
    var cache = Cache.init(fixed.allocator(), &inner);
    defer cache.deinit();

    try std.testing.expectError(error.OutOfMemory, cache.create());
    try std.testing.expectEqual(@as(usize, 0), device.blocksCount());
    try std.testing.expectEqual(@as(usize, 0), cache.physical_page_count);
}

test "Pages: memory reclaiming cache reserves the maximum page ID" {
    const Device = fullaz.device.MemoryBlock(u8);
    const InnerCache = fullaz.storage.page_cache.PageCache(Device);
    const Cache = fullaz.pages.MemoryReclaimingCache(InnerCache);

    var device = try Device.init(std.testing.allocator, 32);
    defer device.deinit();
    var inner = try InnerCache.init(&device, std.testing.allocator, 2);
    defer inner.deinit();
    var cache = Cache.init(std.testing.allocator, &inner);
    defer cache.deinit();

    for (0..std.math.maxInt(u8)) |_| {
        var handle = try cache.create();
        handle.deinit();
    }
    try std.testing.expectError(error.PageIdExhausted, cache.create());
    try std.testing.expectEqual(@as(usize, std.math.maxInt(u8)), device.blocksCount());
    try std.testing.expectEqual(device.blocksCount(), cache.physical_page_count);
}

test "Pages: memory reclaiming cache frees pages without allocating" {
    const Device = fullaz.device.MemoryBlock(u32);
    const InnerCache = fullaz.storage.page_cache.PageCache(Device);
    const Cache = fullaz.pages.MemoryReclaimingCache(InnerCache);

    var device = try Device.init(std.testing.allocator, 256);
    defer device.deinit();
    var inner = try InnerCache.init(&device, std.testing.allocator, 2);
    defer inner.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var cache = Cache.init(failing.allocator(), &inner);
    defer cache.deinit();

    var first = try cache.create();
    const first_id = try first.pid();
    first.deinit();
    var second = try cache.create();
    const second_id = try second.pid();
    second.deinit();

    const alloc_index = failing.alloc_index;
    const resize_index = failing.resize_index;
    failing.fail_index = alloc_index;
    failing.resize_fail_index = resize_index;

    try cache.free(first_id);
    try cache.free(second_id);
    try std.testing.expectEqual(alloc_index, failing.alloc_index);
    try std.testing.expectEqual(resize_index, failing.resize_index);
    try std.testing.expectEqualSlices(u32, &.{ first_id, second_id }, cache.free_pages.items);
    try std.testing.expectError(error.PageAlreadyFree, cache.free(first_id));
    try std.testing.expectError(error.PageNotAllocated, cache.free(2));
    try std.testing.expectError(error.PageNotAllocated, cache.free(std.math.maxInt(u32)));
}
