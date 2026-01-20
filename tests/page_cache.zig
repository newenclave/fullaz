const std = @import("std");
const MemoryDevice = @import("fullaz").device.MemoryBlock;
const PageCache = @import("fullaz").storage.page_cache.PageCache;
const assertBlockDevice = @import("fullaz").device.interfaces.assertBlockDevice;
const isBlockDevice = @import("fullaz").device.interfaces.isBlockDevice;

const testing = std.testing;

test "PageCache: init and deinit" {
    const allocator = testing.allocator;
    var device = try MemoryDevice(u32).init(allocator, 256);
    defer device.deinit();

    var cache = try PageCache(MemoryDevice(u32)).init(&device, allocator, 4);
    defer cache.deinit();

    try testing.expectEqual(4, cache.availableFrames());
    try testing.expectEqual(4, cache.maximum_pages);
}

test "PageCache: fetch loads page from device" {
    const allocator = testing.allocator;
    var device = try MemoryDevice(u32).init(allocator, 256);
    defer device.deinit();

    for (0..5) |_| {
        _ = try device.appendBlock();
    }

    var cache = try PageCache(MemoryDevice(u32)).init(&device, allocator, 4);
    defer cache.deinit();

    // Write some data directly to the device
    var write_buf: [256]u8 = undefined;
    @memset(&write_buf, 0);
    write_buf[0] = 0xAB;
    write_buf[1] = 0xCD;
    try device.writeBlock(0, &write_buf);

    // Fetch through cache
    var handle = try cache.fetch(0);
    defer handle.deinit();

    const data = try handle.getData();
    try testing.expectEqual(@as(u8, 0xAB), data[0]);
    try testing.expectEqual(@as(u8, 0xCD), data[1]);
}

test "PageCache: fetch same page returns cached frame" {
    const allocator = testing.allocator;
    var device = try MemoryDevice(u32).init(allocator, 256);
    defer device.deinit();

    for (0..5) |_| {
        _ = try device.appendBlock();
    }

    var cache = try PageCache(MemoryDevice(u32)).init(&device, allocator, 4);
    defer cache.deinit();

    var handle1 = try cache.fetch(0);
    defer handle1.deinit();

    var handle2 = try cache.fetch(0);
    defer handle2.deinit();

    // Both handles should point to the same frame
    try testing.expectEqual(handle1.frame, handle2.frame);
    try testing.expectEqual(@as(usize, 2), handle1.frame.?.ref_count);
}

test "PageCache: create allocates new page" {
    const allocator = testing.allocator;
    var device = try MemoryDevice(u32).init(allocator, 256);
    defer device.deinit();

    var cache = try PageCache(MemoryDevice(u32)).init(&device, allocator, 4);
    defer cache.deinit();

    const initial_blocks = device.blocksCount();

    var handle = try cache.create();
    defer handle.deinit();

    // Device should have one more block
    try testing.expectEqual(initial_blocks + 1, device.blocksCount());

    // Data should be zeroed
    const data = try handle.getData();
    for (data) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "PageCache: markDirty and flush" {
    const allocator = testing.allocator;
    var device = try MemoryDevice(u32).init(allocator, 256);
    defer device.deinit();

    for (0..5) |_| {
        _ = try device.appendBlock();
    }

    var cache = try PageCache(MemoryDevice(u32)).init(&device, allocator, 4);
    defer cache.deinit();

    var handle = try cache.fetch(0);
    defer handle.deinit();

    // Modify data
    (try handle.getDataMut())[0] = 0xFF;

    // Flush
    try cache.flush(0);

    // Read directly from device to verify
    var read_buf: [256]u8 = undefined;
    try device.readBlock(0, &read_buf);
    try testing.expectEqual(@as(u8, 0xFF), read_buf[0]);
}

test "PageCache: LRU eviction" {
    const allocator = testing.allocator;
    var device = try MemoryDevice(u32).init(allocator, 256);
    defer device.deinit();

    for (0..10) |_| {
        _ = try device.appendBlock();
    }

    var cache = try PageCache(MemoryDevice(u32)).init(&device, allocator, 3);
    defer cache.deinit();

    // Fill the cache with 3 pages
    {
        var h0 = try cache.fetch(0);
        defer h0.deinit();
        var h1 = try cache.fetch(1);
        defer h1.deinit();
        var h2 = try cache.fetch(2);
        defer h2.deinit();

        try testing.expectEqual(@as(usize, 0), cache.availableFrames());
    }

    // All handles released, all frames available for eviction
    try testing.expectEqual(@as(usize, 3), cache.availableFrames());

    // Fetch a new page - should evict the LRU (page 0)
    var h3 = try cache.fetch(3);
    defer h3.deinit();

    // Page 0 should no longer be in cache
    try testing.expect(cache.frames_cache.get(0) == null);

    // Page 3 should be in cache
    try testing.expect(cache.frames_cache.get(3) != null);
}

test "PageCache: pinned pages are not evicted" {
    const allocator = testing.allocator;
    var device = try MemoryDevice(u32).init(allocator, 256);
    defer device.deinit();

    for (0..10) |_| {
        _ = try device.appendBlock();
    }

    var cache = try PageCache(MemoryDevice(u32)).init(&device, allocator, 2);
    defer cache.deinit();

    // Pin page 0
    var pinned = try cache.fetch(0);
    defer pinned.deinit();

    // Fetch page 1
    {
        var h1 = try cache.fetch(1);
        h1.deinit();
    }

    // Fetch page 2 - should evict page 1, not page 0
    var h2 = try cache.fetch(2);
    defer h2.deinit();

    // Page 0 should still be in cache (pinned)
    try testing.expect(cache.frames_cache.get(0) != null);
    // Page 1 should be evicted
    try testing.expect(cache.frames_cache.get(1) == null);
}

test "PageCache: dirty page writeback on eviction" {
    const allocator = testing.allocator;
    var device = try MemoryDevice(u32).init(allocator, 256);
    defer device.deinit();

    for (0..10) |_| {
        _ = try device.appendBlock();
    }

    var cache = try PageCache(MemoryDevice(u32)).init(&device, allocator, 2);
    defer cache.deinit();

    // Fetch and modify page 0
    {
        var h0 = try cache.fetch(0);
        (try h0.getDataMut())[0] = 0x42;
        h0.deinit();
    }

    // Fetch page 1
    {
        var h1 = try cache.fetch(1);
        h1.deinit();
    }

    // Fetch page 2 - should evict page 0 and write it back
    {
        var h2 = try cache.fetch(2);
        h2.deinit();
    }

    // Verify page 0 was written to device
    var read_buf: [256]u8 = undefined;
    try device.readBlock(0, &read_buf);
    try testing.expectEqual(@as(u8, 0x42), read_buf[0]);
}

test "PageCache: getTemporaryPage" {
    const allocator = testing.allocator;
    var device = try MemoryDevice(u32).init(allocator, 256);
    defer device.deinit();

    for (0..5) |_| {
        _ = try device.appendBlock();
    }

    var cache = try PageCache(MemoryDevice(u32)).init(&device, allocator, 4);
    defer cache.deinit();

    var temp = try cache.getTemporaryPage();
    defer temp.deinit();

    // One frame is used for temporary page
    try testing.expectEqual(@as(usize, 3), cache.availableFrames());
}

test "PageCache: clone increases ref_count" {
    const allocator = testing.allocator;
    var device = try MemoryDevice(u32).init(allocator, 256);
    defer device.deinit();

    for (0..5) |_| {
        _ = try device.appendBlock();
    }

    var cache = try PageCache(MemoryDevice(u32)).init(&device, allocator, 4);
    defer cache.deinit();

    var handle = try cache.fetch(0);
    defer handle.deinit();

    try testing.expectEqual(@as(usize, 1), handle.frame.?.ref_count);

    var cloned = try handle.clone();
    defer cloned.deinit();

    try testing.expectEqual(@as(usize, 2), handle.frame.?.ref_count);
    try testing.expectEqual(handle.frame, cloned.frame);
}

test "PageCache: flushAll writes all dirty pages" {
    const allocator = testing.allocator;
    var device = try MemoryDevice(u32).init(allocator, 256);
    defer device.deinit();

    for (0..5) |_| {
        _ = try device.appendBlock();
    }

    var cache = try PageCache(MemoryDevice(u32)).init(&device, allocator, 4);
    defer cache.deinit();

    // Fetch and modify multiple pages
    {
        var h0 = try cache.fetch(0);
        (try h0.getDataMut())[0] = 0x11;
        h0.deinit();
    }
    {
        var h1 = try cache.fetch(1);
        (try h1.getDataMut())[0] = 0x22;
        h1.deinit();
    }

    // Flush all
    try cache.flushAll();

    // Verify both pages were written
    var read_buf: [256]u8 = undefined;

    try device.readBlock(0, &read_buf);
    try testing.expectEqual(@as(u8, 0x11), read_buf[0]);

    try device.readBlock(1, &read_buf);
    try testing.expectEqual(@as(u8, 0x22), read_buf[0]);
}

test "PageCache: fetch moves page to LRU head" {
    const allocator = testing.allocator;
    var device = try MemoryDevice(u32).init(allocator, 256);
    defer device.deinit();

    for (0..10) |_| {
        _ = try device.appendBlock();
    }

    var cache = try PageCache(MemoryDevice(u32)).init(&device, allocator, 3);
    defer cache.deinit();

    // Fill cache: 0, 1, 2 (2 is at head, 0 at tail)
    {
        var h0 = try cache.fetch(0);
        h0.deinit();
    }
    {
        var h1 = try cache.fetch(1);
        h1.deinit();
    }
    {
        var h2 = try cache.fetch(2);
        h2.deinit();
    }

    // Re-fetch page 0 - moves to head
    {
        var h0 = try cache.fetch(0);
        h0.deinit();
    }

    // Fetch page 3 - should evict page 1 (now the LRU)
    var h3 = try cache.fetch(3);
    defer h3.deinit();

    // Page 0 should still be in cache
    try testing.expect(cache.frames_cache.get(0) != null);
    // Page 1 should be evicted
    try testing.expect(cache.frames_cache.get(1) == null);
    // Page 2 should still be in cache
    try testing.expect(cache.frames_cache.get(2) != null);
}

test "PageCache: NoFreeFrames when all pinned" {
    const allocator = testing.allocator;

    var device = try MemoryDevice(u32).init(allocator, 256);
    defer device.deinit();

    for (0..10) |_| {
        _ = try device.appendBlock();
    }

    var cache = try PageCache(MemoryDevice(u32)).init(&device, allocator, 2);
    defer cache.deinit();

    // Pin all frames
    var h0 = try cache.fetch(0);
    defer h0.deinit();
    var h1 = try cache.fetch(1);
    defer h1.deinit();

    // Try to fetch another page
    const result = cache.fetch(2);
    try testing.expectError(error.NoFreeFrames, result);
}
