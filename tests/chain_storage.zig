const std = @import("std");
const chain_store = @import("fullaz").storage.chain_store;
const page_cache = @import("fullaz").storage.page_cache;
const devices = @import("fullaz").device;

const NoneStorageManager = struct {
    pub const Self = @This();
    pub const PageId = u32;
    pub const Size = u32;
    pub const Error = error{};

    first_block_id: ?u32 = null,
    last_block_id: ?u32 = null,
    total_sze: u32 = 0,

    pub fn destroyPage(_: *@This(), id: PageId) Error!void {
        _ = id;
        // Implement page destruction logic, e.g., add to free list
    }

    pub fn getTotalSize(self: *const Self) Error!Size {
        return self.total_sze;
    }

    pub fn setTotalSize(self: *Self, size: Size) Error!void {
        self.total_sze = size;
    }

    pub fn getFirst(self: *const Self) Error!?PageId {
        return self.first_block_id;
    }

    pub fn getLast(self: *const Self) Error!?PageId {
        return self.last_block_id;
    }

    pub fn setFirst(self: *Self, page_id: ?PageId) Error!void {
        self.first_block_id = page_id;
    }

    pub fn setLast(self: *Self, page_id: ?PageId) Error!void {
        self.last_block_id = page_id;
    }
};

test "ChainStore View Test" {
    const Chunk = chain_store.View(u32, u32, u32, std.builtin.Endian.little, false).Chunk;
    var buffer: [1024]u8 = undefined;
    var view = Chunk.init(buffer[0..]);

    view.formatPage(1, 42, 0);

    const sh = view.subheader();
    _ = sh;
    const data = view.getData();
    try std.testing.expect(data.len == (1024 - view.page_view.page().allHeadersSize()));
    const dataMut = view.getDataMut();
    try std.testing.expect(dataMut.len == (1024 - view.page_view.page().allHeadersSize()));
}

test "ChainStore handle: init deinit" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = chain_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();
}

test "ChainStore handle: write page" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = chain_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 1000);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    var page = try hdl.createPage();
    defer page.deinit();

    const test_data = "Hello, ChainStore!";
    var buffer_to_read = [_]u8{0} ** 1000;
    const writ_len_0 = try hdl.writePage(&page, 0, test_data);
    std.debug.print("Write data: {s} res: {d} total: {d}\n", .{ test_data, writ_len_0, try hdl.totalSize() });
    const writ_len_1 = try hdl.writePage(&page, 900, test_data);
    std.debug.print("Write data: {s} res: {d} total: {d}\n", .{ test_data, writ_len_1, try hdl.totalSize() });
    const read_len_0 = try hdl.readPage(&page, 0, &buffer_to_read);

    std.debug.print("read: {any} size: {d}\n", .{ buffer_to_read[0..read_len_0], read_len_0 });
}

test "ChainStore handle: write page handle" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = chain_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 1000);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    try hdl.create();

    for (0..100) |_| {
        const w = try hdl.write("Hello, ChainStore!");
        _ = w;
    }
    var buffer_to_read = [_]u8{0} ** 1000;
    _ = try hdl.read(&buffer_to_read);
    const r = try hdl.read(&buffer_to_read);

    std.debug.print("Handle size: {d}\n", .{try hdl.totalSize()});
    std.debug.print("Read Data {d}: \"{s}\"\n", .{ r, buffer_to_read[0..r] });
}

test "ChainStore Handle. read/write across multiple pages" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = chain_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 1000);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.create();

    // Write data that spans multiple pages (8KB > single page)
    var large_data: [8000]u8 = undefined;
    for (&large_data, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    const written = try hdl.write(&large_data);
    try std.testing.expect(written == large_data.len);
    try std.testing.expect(try hdl.totalSize() == large_data.len);

    // Read back and verify
    try hdl.setg(0);
    var read_buffer: [8000]u8 = undefined;
    const read_count = try hdl.read(&read_buffer);
    try std.testing.expect(read_count == large_data.len);

    // Verify data integrity
    for (large_data, 0..) |expected, i| {
        try std.testing.expect(read_buffer[i] == expected);
    }
}

test "ChainStore Handle. truncate basic" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = chain_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 1000);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.create();

    // Write test data
    const data = "Hello, World!";
    _ = try hdl.write(data);
    try std.testing.expect(try hdl.totalSize() == data.len);

    // Truncate to 5 bytes
    try hdl.truncate(5);
    try std.testing.expect(try hdl.totalSize() == (data.len - 5));

    // Verify truncated data
    try hdl.setg(0);
    var buf: [5]u8 = undefined;
    const read = try hdl.read(&buf);
    try std.testing.expect(read == 5);
    try std.testing.expectEqualStrings("Hello", &buf);
}

test "ChainStore Handle. truncate adjusts get position" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = chain_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 1000);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.create();
    try hdl.open();

    // Write test data
    const data = "0123456789ABCDEF";
    _ = try hdl.write(data);

    // Set get position beyond truncation point
    try hdl.setg(12);
    try std.testing.expect(hdl.g_pos.total_pos == 12);

    // Truncate to 10 bytes
    try hdl.truncate(10);

    // Get position should be adjusted to end
    try std.testing.expect(hdl.g_pos.total_pos == 6);
    try std.testing.expect(try hdl.totalSize() == 6);
}

test "ChainStore Handle. truncate adjusts put position" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = chain_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 1000);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.create();
    try hdl.open();

    // Write test data
    const data = "ABCDEFGHIJKLMNOP";
    _ = try hdl.write(data);

    // Set put position beyond truncation point
    try hdl.setp(14);
    try std.testing.expect(hdl.p_pos.total_pos == 14);

    // Truncate to 8 bytes
    try hdl.truncate(8);

    // Put position should be adjusted to end
    try std.testing.expect(hdl.p_pos.total_pos == 8);
    try std.testing.expect(try hdl.totalSize() == 8);
}

test "ChainStore Handle. truncate adjusts both positions" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = chain_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 1000);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.create();
    try hdl.open();

    // Write test data
    const data = "The quick brown fox";
    _ = try hdl.write(data);

    // Set both positions beyond truncation point
    try hdl.setg(15);
    try hdl.setp(18);
    try std.testing.expect(hdl.g_pos.total_pos == 15);
    try std.testing.expect(hdl.p_pos.total_pos == 18);

    // Truncate to 10 bytes
    try hdl.truncate(10);

    // Both positions should be adjusted
    try std.testing.expect(hdl.g_pos.total_pos == 9);
    try std.testing.expect(hdl.p_pos.total_pos == 9);
    try std.testing.expect(try hdl.totalSize() == 9);

    // Verify data integrity
    try hdl.setg(0);
    var buf: [9]u8 = undefined;
    const read = try hdl.read(&buf);
    try std.testing.expect(read == 9);
    try std.testing.expectEqualStrings("The quick", &buf);
}

test "ChainStore Handle. truncate to zero" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = chain_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 1000);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.create();
    try hdl.open();

    // Write test data
    const data = "Some data";
    _ = try hdl.write(data);
    try std.testing.expect(try hdl.totalSize() == data.len);

    // Truncate to 0
    try hdl.truncate(1);
    try std.testing.expect(try hdl.totalSize() == data.len - 1);
    try std.testing.expect(hdl.g_pos.total_pos == 0);
    try std.testing.expect(hdl.p_pos.total_pos == data.len - 1);
}

test "ChainStore Handle. truncate preserves data within range" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = chain_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 1000);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.create();
    try hdl.open();

    // Write test data
    const data = "0123456789ABCDEFGHIJ";
    _ = try hdl.write(data);

    // Truncate to 12 bytes
    try hdl.truncate(8);

    // Verify data before truncation is preserved
    try hdl.setg(0);
    var buf: [12]u8 = undefined;
    const read = try hdl.read(&buf);
    try std.testing.expect(read == 12);
    try std.testing.expectEqualStrings("0123456789AB", &buf);
}

test "ChainStore Handle. truncate with large data across pages" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = chain_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 1000);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.create();
    try hdl.open();

    // Write large data spanning multiple pages
    var large_data: [5000]u8 = undefined;
    for (&large_data, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }
    _ = try hdl.write(&large_data);
    const original_size = try hdl.totalSize();
    try std.testing.expect(original_size == 5000);

    // Set positions
    try hdl.setg(2500);
    try hdl.setp(4500);

    // Truncate to 3000 bytes
    try hdl.truncate(2000);

    try std.testing.expect(try hdl.totalSize() == 3000);
    // Get position beyond truncation, should be adjusted
    try std.testing.expect(hdl.g_pos.total_pos == 2500);
    // Put position beyond truncation, should be adjusted
    try std.testing.expect(hdl.p_pos.total_pos == 3000);

    // Verify data integrity of remaining data
    try hdl.setg(0);
    var read_buffer: [3000]u8 = undefined;
    const read = try hdl.read(&read_buffer);
    try std.testing.expect(read == 3000);

    // Verify first 3000 bytes match original
    for (large_data[0..3000], 0..) |expected, i| {
        try std.testing.expect(read_buffer[i] == expected);
    }
}

test "ChainStore Handle. truncate position within range not affected" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = chain_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 1000);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.create();
    try hdl.open();

    // Write test data
    const data = "0123456789ABCDEFGHIJ";
    _ = try hdl.write(data);

    // Set positions within the truncation range
    try hdl.setg(3);
    try hdl.setp(7);

    // Truncate to 15 bytes (positions are within this range)
    try hdl.truncate(5);

    // Positions should NOT be adjusted since they're within range
    try std.testing.expect(hdl.g_pos.total_pos == 3);
    try std.testing.expect(hdl.p_pos.total_pos == 7);
    try std.testing.expect(try hdl.totalSize() == 15);
}

test "ChainStore Handle. truncate more than have" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = chain_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 1000);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.create();
    try hdl.open();

    // Write test data
    const data = "0123456789ABCDEFGHIJ";
    _ = try hdl.write(data);

    // Set positions within the truncation range
    try hdl.setg(3);
    try hdl.setp(7);

    // Truncate to 15 bytes (positions are within this range)
    try hdl.truncate(500);

    // Positions should NOT be adjusted since they're within range
    try std.testing.expect(hdl.g_pos.total_pos == 0);
    try std.testing.expect(hdl.p_pos.total_pos == 0);
    try std.testing.expect(try hdl.totalSize() == 0);
}

test "ChainStore Handle. extend basic" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = chain_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 1000);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.create();
    try hdl.open();

    // Write initial data
    const data = "Hello";
    _ = try hdl.write(data);
    try std.testing.expect(try hdl.totalSize() == 5);

    // Extend by 5 bytes
    try hdl.extend(5);
    try std.testing.expect(try hdl.totalSize() == 10);

    // Verify original data is intact and extension is zeroed
    try hdl.setg(0);
    var buf: [10]u8 = undefined;
    const read = try hdl.read(&buf);
    try std.testing.expect(read == 10);
    try std.testing.expectEqualStrings("Hello", buf[0..5]);
    // Extended bytes should be zero
    for (buf[5..10]) |byte| {
        try std.testing.expect(byte == 0);
    }
}

test "ChainStore Handle. extend empty file" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = chain_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 1000);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.create();
    try hdl.open();

    // Extend empty file
    try hdl.extend(10);
    try std.testing.expect(try hdl.totalSize() == 10);

    // All bytes should be zero
    try hdl.setg(0);
    var buf: [10]u8 = undefined;
    const read = try hdl.read(&buf);
    try std.testing.expect(read == 10);
    for (buf) |byte| {
        try std.testing.expect(byte == 0);
    }
}

test "ChainStore Handle. extend with large size" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = chain_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 1000);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.create();
    try hdl.open();

    // Write some data
    const data = "Start";
    _ = try hdl.write(data);
    try std.testing.expect(try hdl.totalSize() == 5);

    // Extend by 5000 bytes (spans multiple pages)
    try hdl.extend(5000);
    try std.testing.expect(try hdl.totalSize() == 5005);

    // Verify original data
    try hdl.setg(0);
    var buf_start: [5]u8 = undefined;
    _ = try hdl.read(&buf_start);
    try std.testing.expectEqualStrings("Start", &buf_start);

    // Verify extended region is zeroed (sample check)
    try hdl.setg(100);
    var buf_middle: [100]u8 = undefined;
    const read_middle = try hdl.read(&buf_middle);
    try std.testing.expect(read_middle == 100);
    for (buf_middle) |byte| {
        try std.testing.expect(byte == 0);
    }

    // Verify end of file
    try hdl.setg(5000);
    var buf_end: [5]u8 = undefined;
    const read_end = try hdl.read(&buf_end);
    try std.testing.expect(read_end == 5);
    for (buf_end) |byte| {
        try std.testing.expect(byte == 0);
    }
}

test "ChainStore Handle. extend and write to extended region" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = chain_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 1000);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.create();
    try hdl.open();

    // Write initial data
    const data1 = "ABC";
    _ = try hdl.write(data1);
    try std.testing.expect(try hdl.totalSize() == 3);

    // Extend by 10 bytes
    try hdl.extend(10);
    try std.testing.expect(try hdl.totalSize() == 13);

    // Write to the extended region
    try hdl.setp(5);
    const data2 = "XYZ";
    _ = try hdl.write(data2);

    // Verify complete data
    try hdl.setg(0);
    var buf: [13]u8 = undefined;
    const read = try hdl.read(&buf);
    try std.testing.expect(read == 13);

    // "ABC" + 2 zeros + "XYZ" + 5 zeros
    try std.testing.expectEqualStrings("ABC", buf[0..3]);
    try std.testing.expect(buf[3] == 0);
    try std.testing.expect(buf[4] == 0);
    try std.testing.expectEqualStrings("XYZ", buf[5..8]);
    for (buf[8..13]) |byte| {
        try std.testing.expect(byte == 0);
    }
}

test "ChainStore Handle. extend multiple times" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = chain_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 1000);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.create();
    try hdl.open();

    // Write initial data
    const data = "A";
    _ = try hdl.write(data);
    try std.testing.expect(try hdl.totalSize() == 1);

    // Extend multiple times
    try hdl.extend(5);
    try std.testing.expect(try hdl.totalSize() == 6);

    try hdl.extend(4);
    try std.testing.expect(try hdl.totalSize() == 10);

    try hdl.extend(10);
    try std.testing.expect(try hdl.totalSize() == 20);

    // Verify
    try hdl.setg(0);
    var buf: [20]u8 = undefined;
    const read = try hdl.read(&buf);
    try std.testing.expect(read == 20);
    try std.testing.expect(buf[0] == 'A');
    for (buf[1..20]) |byte| {
        try std.testing.expect(byte == 0);
    }
}

test "ChainStore Handle. extend preserves positions" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = chain_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 1000);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.create();
    try hdl.open();

    // Write data
    const data = "0123456789";
    _ = try hdl.write(data);

    // Set positions
    try hdl.setg(3);
    try hdl.setp(7);

    // Extend
    try hdl.extend(5);

    // Positions should remain unchanged
    try std.testing.expect(hdl.g_pos.total_pos == 3);
    try std.testing.expect(hdl.p_pos.total_pos == 7);
    try std.testing.expect(try hdl.totalSize() == 15);

    // Can still read from get position
    var buf: [7]u8 = undefined;
    const read = try hdl.read(&buf);
    try std.testing.expect(read == 7);
    try std.testing.expectEqualStrings("3456789", &buf);
}

test "ChainStore Handle. extend zero length" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = chain_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 1000);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.create();
    try hdl.open();

    const data = "Test";
    _ = try hdl.write(data);
    const size_before = try hdl.totalSize();

    // Extend by 0 should have no effect
    try hdl.extend(0);
    try std.testing.expect(try hdl.totalSize() == size_before);
}

test "ChainStore Handle. extend then truncate" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = chain_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 1000);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.create();
    try hdl.open();

    // Write, extend, then truncate
    const data = "Hello";
    _ = try hdl.write(data);
    try std.testing.expect(try hdl.totalSize() == 5);

    try hdl.extend(10);
    try std.testing.expect(try hdl.totalSize() == 15);

    try hdl.truncate(7);
    try std.testing.expect(try hdl.totalSize() == 8);

    // Verify data
    try hdl.setg(0);
    var buf: [8]u8 = undefined;
    const read = try hdl.read(&buf);
    try std.testing.expect(read == 8);
    try std.testing.expectEqualStrings("Hello", buf[0..5]);
    for (buf[5..8]) |byte| {
        try std.testing.expect(byte == 0);
    }
}

test "ChainStore Handle. extend spanning multiple chunks" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = chain_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 1000);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.create();
    try hdl.open();

    // Write small initial data
    const data = "X";
    _ = try hdl.write(data);
    try std.testing.expect(try hdl.totalSize() == 1);

    // Extend by a large amount to span multiple chunks
    try hdl.extend(10000);
    try std.testing.expect(try hdl.totalSize() == 10001);

    // Verify original byte
    try hdl.setg(0);
    var first: [1]u8 = undefined;
    _ = try hdl.read(&first);
    try std.testing.expect(first[0] == 'X');

    // Sample check extended region for zeros
    try hdl.setg(5000);
    var sample: [100]u8 = undefined;
    const read_sample = try hdl.read(&sample);
    try std.testing.expect(read_sample == 100);
    for (sample) |byte| {
        try std.testing.expect(byte == 0);
    }
}
