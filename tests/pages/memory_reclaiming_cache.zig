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

    var fetched = try cache.fetch(page_id);
    fetched.deinit();
    try cache.flush(page_id);
    try cache.flushAll();
}
