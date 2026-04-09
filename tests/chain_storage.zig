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

test "LongStore Handle. read/write across multiple pages" {
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
