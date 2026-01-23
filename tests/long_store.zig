const std = @import("std");
const long_store = @import("fullaz").storage.long_store;
const page_cache = @import("fullaz").storage.page_cache;
const devices = @import("fullaz").device;

const NoneStorageManager = struct {
    pub const Self = @This();
    pub const PageId = u32;
    pub const Error = error{};
    root_block_id: ?u32 = null,

    pub fn getRoot(self: *const @This()) ?u32 {
        return self.root_block_id;
    }

    pub fn setRoot(self: *@This(), root: ?u32) Error!void {
        self.root_block_id = root;
        // Persist to disk header, etc.
    }

    pub fn hasRoot(self: *const @This()) bool {
        return self.root_block_id != null;
    }

    pub fn destroyPage(_: *@This(), id: PageId) Error!void {
        _ = id;
        // Implement page destruction logic, e.g., add to free list
    }
};

test "LongStore Create a header view" {
    const HeaderViewType = long_store.View(u32, u32, u32, std.builtin.Endian.little, false).HeaderView;
    var buffer: [1024]u8 = undefined;
    var view = HeaderViewType.init(buffer[0..]);

    view.formatPage(1, 42, 0);

    const sh = view.subheader();
    try std.testing.expect(sh.total_size.get() == 0);
    try std.testing.expect(sh.link.back.get() == @TypeOf(sh.link.back).max());
    try std.testing.expect(sh.link.fwd.get() == @TypeOf(sh.link.fwd).max());
    try std.testing.expect(sh.link.payload.size.get() == 0);
    try std.testing.expect(sh.link.payload.reserved.get() == 0);
    const data = view.data();
    try std.testing.expect(data.len == (1024 - view.pageView().allHeadersSize()));
    const dataMut = view.dataMut();
    try std.testing.expect(dataMut.len == (1024 - view.pageView().allHeadersSize()));
}

test "LongStore Create a Chunk view" {
    const ChunkViewType = long_store.View(u32, u32, u32, std.builtin.Endian.little, false).ChunkView;
    var buffer: [1024]u8 = undefined;
    var view = ChunkViewType.init(buffer[0..]);

    view.formatPage(1, 42, 0);

    const sh = view.subheader();
    try std.testing.expect(sh.link.back.get() == @TypeOf(sh.link.back).max());
    try std.testing.expect(sh.link.fwd.get() == @TypeOf(sh.link.fwd).max());
    try std.testing.expect(sh.link.payload.size.get() == 0);
    try std.testing.expect(sh.link.payload.reserved.get() == 0);
}

test "HeaderView getNext/setNext" {
    const HeaderViewType = long_store.View(u32, u32, u32, std.builtin.Endian.little, false).HeaderView;
    var buffer: [1024]u8 = undefined;
    var view = HeaderViewType.init(buffer[0..]);
    view.formatPage(1, 42, 0);

    // Test null next
    try std.testing.expect(view.getLink().getFwd() == null);

    // Test set next
    var link = view.getLinkMut();
    link.setFwd(100);
    try std.testing.expect(view.getLink().getFwd() == 100);

    // Test set next to null
    link.setFwd(null);
    try std.testing.expect(view.getLink().getFwd() == null);
}

test "HeaderView getLast/setLast" {
    const HeaderViewType = long_store.View(u32, u32, u32, std.builtin.Endian.little, false).HeaderView;
    var buffer: [1024]u8 = undefined;
    var view = HeaderViewType.init(buffer[0..]);
    view.formatPage(1, 42, 0);

    // Test null last
    try std.testing.expect(view.getLink().getBack() == null);

    // Test set last
    var link = view.getLinkMut();
    link.setBack(200);
    try std.testing.expect(view.getLink().getBack() == 200);
    // Test set last to null
    link.setBack(null);
    try std.testing.expect(view.getLink().getBack() == null);
}

test "HeaderView getTotalSize/setTotalSize" {
    const HeaderViewType = long_store.View(u32, u32, u32, std.builtin.Endian.little, false).HeaderView;
    var buffer: [1024]u8 = undefined;
    var view = HeaderViewType.init(buffer[0..]);
    view.formatPage(1, 42, 0);

    // Test initial total size is 0
    try std.testing.expect(view.getTotalSize() == 0);

    // Test set total size
    view.setTotalSize(500);
    try std.testing.expect(view.getTotalSize() == 500);
}

test "HeaderView incrementTotalSize/decrementTotalSize" {
    const HeaderViewType = long_store.View(u32, u32, u32, std.builtin.Endian.little, false).HeaderView;
    var buffer: [1024]u8 = undefined;
    var view = HeaderViewType.init(buffer[0..]);
    view.formatPage(1, 42, 0);

    view.setTotalSize(100);
    view.incrementTotalSize(50);
    try std.testing.expect(view.getTotalSize() == 150);

    view.decrementTotalSize(30);
    try std.testing.expect(view.getTotalSize() == 120);
}

test "HeaderView getDataSize/setDataSize" {
    const HeaderViewType = long_store.View(u32, u32, u32, std.builtin.Endian.little, false).HeaderView;
    var buffer: [1024]u8 = undefined;
    var view = HeaderViewType.init(buffer[0..]);
    view.formatPage(1, 42, 0);

    // Test initial data size is 0
    try std.testing.expect(view.getLink().getDataSize() == 0);

    // Test set data size
    var link = view.getLinkMut();
    link.setDataSize(256);
    try std.testing.expect(view.getLink().getDataSize() == 256);
}

test "HeaderView incrementDataSize/decrementDataSize" {
    const HeaderViewType = long_store.View(u32, u32, u32, std.builtin.Endian.little, false).HeaderView;
    var buffer: [1024]u8 = undefined;
    var view = HeaderViewType.init(buffer[0..]);
    view.formatPage(1, 42, 0);

    var link = view.getLinkMut();

    link.setDataSize(100);

    link.incrementDataSize(25);
    try std.testing.expect(view.getLink().getDataSize() == 125);

    link.decrementDataSize(15);
    try std.testing.expect(view.getLink().getDataSize() == 110);
}

test "ChunkView getNext/setNext" {
    const ChunkViewType = long_store.View(u32, u32, u32, std.builtin.Endian.little, false).ChunkView;
    var buffer: [1024]u8 = undefined;
    var view = ChunkViewType.init(buffer[0..]);
    view.formatPage(1, 42, 0);

    // Test null next
    try std.testing.expect(view.getLink().getFwd() == null);

    // Test set next
    var link = view.getLinkMut();
    link.setFwd(150);
    try std.testing.expect(view.getLink().getFwd() == 150);

    // Test set next to null
    link.setFwd(null);
    try std.testing.expect(view.getLink().getFwd() == null);
}

test "ChunkView getPrev/setPrev" {
    const ChunkViewType = long_store.View(u32, u32, u32, std.builtin.Endian.little, false).ChunkView;
    var buffer: [1024]u8 = undefined;
    var view = ChunkViewType.init(buffer[0..]);
    view.formatPage(1, 42, 0);

    // Test null prev
    try std.testing.expect(view.getLink().getBack() == null);

    // Test set prev
    var link = view.getLinkMut();
    link.setBack(99);
    try std.testing.expect(view.getLink().getBack() == 99);

    // Test set prev to null
    link.setBack(null);
    try std.testing.expect(view.getLink().getBack() == null);
}

test "ChunkView getDataSize/setDataSize" {
    const ChunkViewType = long_store.View(u32, u32, u32, std.builtin.Endian.little, false).ChunkView;
    var buffer: [1024]u8 = undefined;
    var view = ChunkViewType.init(buffer[0..]);
    view.formatPage(1, 42, 0);

    // Test initial data size is 0
    try std.testing.expect(view.getLink().getDataSize() == 0);

    // Test set data size
    var link = view.getLinkMut();
    link.setDataSize(512);
    try std.testing.expect(view.getLink().getDataSize() == 512);
}

test "ChunkView incrementDataSize/decrementDataSize" {
    const ChunkViewType = long_store.View(u32, u32, u32, std.builtin.Endian.little, false).ChunkView;
    var buffer: [1024]u8 = undefined;
    var view = ChunkViewType.init(buffer[0..]);
    view.formatPage(1, 42, 0);

    var link = view.getLinkMut();

    link.setDataSize(100);
    link.incrementDataSize(40);
    try std.testing.expect(view.getLink().getDataSize() == 140);

    link.decrementDataSize(20);
    try std.testing.expect(view.getLink().getDataSize() == 120);
}

test "ChunkView hasFlag/setFlag/clearFlag" {
    const ChunkViewType = long_store.View(u32, u32, u32, std.builtin.Endian.little, false).ChunkView;
    var buffer: [1024]u8 = undefined;
    var view = ChunkViewType.init(buffer[0..]);
    view.formatPage(1, 42, 0);

    // Test flag not set initially
    try std.testing.expect(!view.hasFlag(ChunkViewType.Flags.first));

    // Test set flag
    view.setFlag(ChunkViewType.Flags.first);
    try std.testing.expect(view.hasFlag(.first));

    // Test clear flag
    view.clearFlag(ChunkViewType.Flags.first);
    try std.testing.expect(!view.hasFlag(.first));
}

test "LongStore Handle. Create, openm load" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = long_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};

    var dev = try Device.init(std.testing.allocator, 4096);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    const header_pid = try hdl.create();
    try std.testing.expect(header_pid == 0);

    try hdl.open();
    try std.testing.expect(try hdl.totalSize() == 0);
    const header = try hdl.loadHeader();
    try std.testing.expect(try header.handle.pid() == header_pid);

    var cursor = try hdl.begin();
    defer cursor.deinit();
    const cpid = try cursor.pid();
    try std.testing.expect((try cursor.currentDataSize()) == 0);
    try std.testing.expect((try cursor.currentData()).len == 0);

    try cursor.setCurrentDataSize(100);
    try std.testing.expect((try cursor.currentDataSize()) == 100);
    try std.testing.expect((try cursor.currentData()).len == 100);

    const max_data_size = try cursor.getMaximumDataSize();
    std.debug.print("Max data size: {}\n", .{max_data_size});
    try cursor.setCurrentDataSize(max_data_size);

    try std.testing.expect((try cursor.currentDataSize()) == max_data_size);

    var tc = try hdl.appendGetChunk();
    defer tc.deinit();

    try cursor.moveNext();
    try std.testing.expect((try cursor.currentDataSize()) == 0);
    try cursor.movePrev();
    try std.testing.expect((try cursor.currentDataSize()) == max_data_size);
    try std.testing.expectEqual(try cursor.pid(), cpid);
}

test "LongStore Handle. Check create next" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = long_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};

    var dev = try Device.init(std.testing.allocator, 4096);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    const header_pid = try hdl.create();
    try std.testing.expect(header_pid == 0);

    try hdl.open();
    try std.testing.expect(try hdl.totalSize() == 0);
    const header = try hdl.loadHeader();
    try std.testing.expect(try header.handle.pid() == header_pid);

    var cursor = try hdl.begin();

    try std.testing.expect(try cursor.hasNext() == false);
    try hdl.appendChunk();
    try std.testing.expect(try cursor.hasNext() == true);
    try hdl.popChunk();
    try std.testing.expect(try cursor.hasNext() == false);
}

test "LongStore Handle. write read" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = long_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};

    var dev = try Device.init(std.testing.allocator, 4096);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.create();
    try hdl.open();
    const data: [7000]u8 = undefined;
    const written = try hdl.write(&data);
    try std.testing.expect(written == data.len);
    try std.testing.expect(try hdl.totalSize() == data.len);

    // hdl.set_page_pid = hdl.header_pid;
    // hdl.set_pos = 0;
    const written2 = try hdl.write(&data);
    try std.testing.expect(written2 == data.len);
    try std.testing.expect(try hdl.totalSize() == (data.len * 2));
    try hdl.setp(9000);
    const written3 = try hdl.write(&data);
    try std.testing.expect(written3 == data.len);
    const total_size = try hdl.totalSize();
    std.debug.print("Total size: {}\n", .{total_size});
    try std.testing.expect(total_size == (data.len * 2) + 2000);

    try hdl.setp(15999);
    std.debug.print("Writing at pos {}\n", .{hdl.put_total_pos});

    var rdata: [7000]u8 = undefined;
    const read = try hdl.read(&rdata);
    try std.testing.expect(read == 7000);
    try std.testing.expect(rdata[0] == 0);
}

test "LongStore Handle. setp - set put position" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = long_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.create();
    try hdl.open();

    // Initial state
    try std.testing.expect(hdl.put_total_pos == 0);

    // Write some initial data
    const data1 = "Hello, World!";
    _ = try hdl.write(data1);
    try std.testing.expect(hdl.put_total_pos == data1.len);

    // Set put position to beginning
    try hdl.setp(0);
    try std.testing.expect(hdl.put_total_pos == 0);

    // Overwrite from beginning
    const data2 = "HELLO";
    _ = try hdl.write(data2);
    try std.testing.expect(hdl.put_total_pos == data2.len);

    // Set put position to middle
    try hdl.setp(5);
    try std.testing.expect(hdl.put_total_pos == 5);

    // Write at middle position
    const data3 = "XXX";
    _ = try hdl.write(data3);
    try std.testing.expect(hdl.put_total_pos == 8);

    // Set put position to end
    try hdl.setp(data1.len);
    const data4 = " More data";
    _ = try hdl.write(data4);
    try std.testing.expect(hdl.put_total_pos == data1.len + data4.len);
}

test "LongStore Handle. setg - set get position" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = long_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.create();
    try hdl.open();

    // Write test data
    const data = "Hello, World! This is a test.";
    _ = try hdl.write(data);

    // Initial get position
    try std.testing.expect(hdl.get_total_pos == 0);

    // Set get position to beginning and read
    try hdl.setg(0);
    var buf1: [5]u8 = undefined;
    const read1 = try hdl.read(&buf1);
    try std.testing.expect(read1 == 5);
    try std.testing.expectEqualStrings("Hello", &buf1);

    // Set get position to middle
    try hdl.setg(7);
    var buf2: [5]u8 = undefined;
    const read2 = try hdl.read(&buf2);
    try std.testing.expect(read2 == 5);
    try std.testing.expectEqualStrings("World", &buf2);

    // Set get position back to beginning
    try hdl.setg(0);
    var buf3: [13]u8 = undefined;
    const read3 = try hdl.read(&buf3);
    try std.testing.expect(read3 == 13);
    try std.testing.expectEqualStrings("Hello, World!", &buf3);
}

test "LongStore Handle. read basic operations" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = long_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.create();
    try hdl.open();

    // Write test data
    const test_data = "The quick brown fox jumps over the lazy dog";
    _ = try hdl.write(test_data);

    // Read all data
    try hdl.setg(0);
    var buf1: [43]u8 = undefined;
    const read1 = try hdl.read(&buf1);
    try std.testing.expect(read1 == test_data.len);
    try std.testing.expectEqualStrings(test_data, &buf1);

    // Read partial data from beginning
    try hdl.setg(0);
    var buf2: [9]u8 = undefined;
    const read2 = try hdl.read(&buf2);
    try std.testing.expect(read2 == 9);
    try std.testing.expectEqualStrings("The quick", &buf2);

    // Read partial data from middle
    try hdl.setg(10);
    var buf3: [5]u8 = undefined;
    const read3 = try hdl.read(&buf3);
    try std.testing.expect(read3 == 5);
    try std.testing.expectEqualStrings("brown", &buf3);

    // Read beyond end (should read until end)
    try hdl.setg(40);
    var buf4: [10]u8 = undefined;
    const read4 = try hdl.read(&buf4);
    try std.testing.expect(read4 == 3);
    try std.testing.expectEqualStrings("dog", buf4[0..3]);
}

test "LongStore Handle. write basic operations" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = long_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.create();
    try hdl.open();

    // Write initial data
    const data1 = "First line\n";
    const written1 = try hdl.write(data1);
    try std.testing.expect(written1 == data1.len);
    try std.testing.expect(try hdl.totalSize() == data1.len);

    // Append more data
    const data2 = "Second line\n";
    const written2 = try hdl.write(data2);
    try std.testing.expect(written2 == data2.len);
    try std.testing.expect(try hdl.totalSize() == data1.len + data2.len);

    // Overwrite from beginning
    try hdl.setp(0);
    const data3 = "REPLACED";
    const written3 = try hdl.write(data3);
    try std.testing.expect(written3 == data3.len);

    // Verify overwrite
    try hdl.setg(0);
    var buf: [8]u8 = undefined;
    _ = try hdl.read(&buf);
    try std.testing.expectEqualStrings("REPLACED", &buf);

    // Write at specific position (middle)
    try hdl.setp(5);
    const data4 = "INSERTED";
    _ = try hdl.write(data4);

    // Verify insertion
    try hdl.setg(5);
    var buf2: [8]u8 = undefined;
    _ = try hdl.read(&buf2);
    try std.testing.expectEqualStrings("INSERTED", &buf2);
}

test "LongStore Handle. read/write across multiple pages" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = long_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.create();
    try hdl.open();

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

test "LongStore Handle. setg/setp independent positioning" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = long_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.create();
    try hdl.open();

    // Write initial data
    const initial = "0123456789ABCDEFGHIJ";
    _ = try hdl.write(initial);

    // Set different positions for get and put
    try hdl.setg(5); // Read position at 5
    try hdl.setp(10); // Write position at 10

    try std.testing.expect(hdl.get_total_pos == 5);
    try std.testing.expect(hdl.put_total_pos == 10);

    // Write at put position
    const write_data = "XXX";
    _ = try hdl.write(write_data);

    // Read at get position (should not be affected by write position)
    var read_buf: [5]u8 = undefined;
    _ = try hdl.read(&read_buf);
    try std.testing.expectEqualStrings("56789", &read_buf);

    // Verify write happened at correct position
    try hdl.setg(10);
    var verify_buf: [3]u8 = undefined;
    _ = try hdl.read(&verify_buf);
    try std.testing.expectEqualStrings("XXX", &verify_buf);
}

test "LongStore Handle. truncate basic" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = long_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.create();
    try hdl.open();

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

test "LongStore Handle. truncate adjusts get position" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = long_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
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
    try std.testing.expect(hdl.get_total_pos == 12);

    // Truncate to 10 bytes
    try hdl.truncate(10);

    // Get position should be adjusted to end
    try std.testing.expect(hdl.get_total_pos == 6);
    try std.testing.expect(try hdl.totalSize() == 6);
}

test "LongStore Handle. truncate adjusts put position" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = long_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
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
    try std.testing.expect(hdl.put_total_pos == 14);

    // Truncate to 8 bytes
    try hdl.truncate(8);

    // Put position should be adjusted to end
    try std.testing.expect(hdl.put_total_pos == 8);
    try std.testing.expect(try hdl.totalSize() == 8);
}

test "LongStore Handle. truncate adjusts both positions" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = long_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
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
    try std.testing.expect(hdl.get_total_pos == 15);
    try std.testing.expect(hdl.put_total_pos == 18);

    // Truncate to 10 bytes
    try hdl.truncate(10);

    // Both positions should be adjusted
    try std.testing.expect(hdl.get_total_pos == 9);
    try std.testing.expect(hdl.put_total_pos == 9);
    try std.testing.expect(try hdl.totalSize() == 9);

    // Verify data integrity
    try hdl.setg(0);
    var buf: [9]u8 = undefined;
    const read = try hdl.read(&buf);
    try std.testing.expect(read == 9);
    try std.testing.expectEqualStrings("The quick", &buf);
}

test "LongStore Handle. truncate to zero" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = long_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
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
    try std.testing.expect(hdl.get_total_pos == 0);
    try std.testing.expect(hdl.put_total_pos == data.len - 1);
}

test "LongStore Handle. truncate preserves data within range" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = long_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
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

test "LongStore Handle. truncate with large data across pages" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = long_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
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
    try std.testing.expect(hdl.get_total_pos == 2500);
    // Put position beyond truncation, should be adjusted
    try std.testing.expect(hdl.put_total_pos == 3000);

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

test "LongStore Handle. truncate position within range not affected" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = long_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
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
    try std.testing.expect(hdl.get_total_pos == 3);
    try std.testing.expect(hdl.put_total_pos == 7);
    try std.testing.expect(try hdl.totalSize() == 15);
}

test "LongStore Handle. truncate more than have" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = long_store.Handle(Cache, NoneStorageManager);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
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
    try std.testing.expect(hdl.get_total_pos == 0);
    try std.testing.expect(hdl.put_total_pos == 0);
    try std.testing.expect(try hdl.totalSize() == 0);
}
