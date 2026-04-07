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

test "CheinStore View Test" {
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

test "CheinStore handle" {
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
