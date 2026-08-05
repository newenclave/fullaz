const std = @import("std");
const fullaz = @import("fullaz");
const slot_chain = fullaz.storage.slot_chain;

const page_cache = @import("fullaz").storage.page_cache;
const devices = @import("fullaz").device;
const printer = @import("test_printer");

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

test "SlotChain: create" {
    const View = slot_chain.View(u32, u32, .little, false);
    const Chunk = View.Chunk;

    var page: [1024]u8 = undefined;
    var c = Chunk.init(&page);
    try c.formatPage(1, 42, 0);
    try std.testing.expect(c.view.header().kind.get() == 1);
    try std.testing.expect(c.view.header().additional.links.prev.isMax());
    try std.testing.expect(c.view.header().additional.links.next.isMax());
}

test "SlotChain: handle" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = slot_chain.Handle(Cache, NoneStorageManager, .little);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    _ = dev.appendBlock() catch {};

    var hdl = try Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    _ = try hdl.append("Hello");
    _ = try hdl.append("World");

    var p = try hdl.loadPage(1);
    defer p.deinit();

    try std.testing.expect(try p.id() == 1);
    try std.testing.expect(try p.size() == 2);
}
