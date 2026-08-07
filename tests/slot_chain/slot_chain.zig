const std = @import("std");
const fullaz = @import("fullaz");
const slot_chain = fullaz.storage.slot_chain;

const page_cache = @import("fullaz").storage.page_cache;
const devices = @import("fullaz").device;
const fsm = @import("fullaz").storage.fsm;
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
    try std.testing.expect(c.view.getNext() == null);
    try std.testing.expect(c.view.getPrev() == null);
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

    try p.setTombstone(1);

    try std.testing.expect(try p.id() == 1);
    try std.testing.expect(try p.size() == 2);
    try std.testing.expect(try p.isTombstone(1));
    try std.testing.expect(!try p.isTombstone(0));

    const removed = try p.removeTombstones();
    try std.testing.expect(removed == 1);
    try std.testing.expect(try p.size() == 1);
    try std.testing.expect(!try p.isTombstone(0));
}

test "SlotChain: iterator" {
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

    _ = try hdl.append("first");
    _ = try hdl.append("second");

    var page = try hdl.loadPage(1);
    defer page.deinit();
    try page.setTombstone(0);

    var itr = (try hdl.iterator()).?;
    defer itr.deinit();

    const first = (try itr.next()).?;
    try std.testing.expectEqualStrings("second", first.value);
    try std.testing.expect((try itr.next()) == null);

    const last = (try itr.prev()).?;
    try std.testing.expectEqualStrings("second", last.value);
    try std.testing.expect((try itr.prev()) == null);
}

test "SlotChain: iterator crosses chunks" {
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

    var first: [3000]u8 = undefined;
    @memset(&first, 'a');
    var second: [3000]u8 = undefined;
    @memset(&second, 'b');
    _ = try hdl.append(&first);
    _ = try hdl.append(&second);

    var itr = (try hdl.iterator()).?;
    defer itr.deinit();

    const first_result = (try itr.next()).?;
    try std.testing.expectEqual(@as(u8, 'a'), first_result.value[0]);
    const second_result = (try itr.next()).?;
    try std.testing.expectEqual(@as(u8, 'b'), second_result.value[0]);
    try std.testing.expect((try itr.next()) == null);

    const last_result = (try itr.prev()).?;
    try std.testing.expectEqual(@as(u8, 'b'), last_result.value[0]);
    const previous_result = (try itr.prev()).?;
    try std.testing.expectEqual(@as(u8, 'a'), previous_result.value[0]);

    var reverse_itr = (try hdl.iteratorFromEnd()).?;
    defer reverse_itr.deinit();
    const reverse_last = (try reverse_itr.prev()).?;
    try std.testing.expectEqual(@as(u8, 'b'), reverse_last.value[0]);
    const reverse_first = (try reverse_itr.prev()).?;
    try std.testing.expectEqual(@as(u8, 'a'), reverse_first.value[0]);
}

test "SlotChain: insertUnordered falls back to append without FSM" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = slot_chain.Handle(Cache, NoneStorageManager, .little);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = try Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    try hdl.insertUnordered("first");
    try hdl.insertUnordered("second");
    try std.testing.expectEqual(@as(u32, 2), try hdl.size());

    var itr = (try hdl.iterator()).?;
    defer itr.deinit();
    try std.testing.expectEqualStrings("first", (try itr.next()).?.value);
    try std.testing.expectEqualStrings("second", (try itr.next()).?.value);
}

test "SlotChain: insertUnordered uses FSM free-space index" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const FsmModel = fsm.models.Memory(u32, u16);
    const Fsm = fsm.Fsm(FsmModel);
    const Handle = slot_chain.HandleImpl(Cache, NoneStorageManager, void, void, Fsm, .little);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();
    var fsm_model = try FsmModel.init(std.testing.allocator);
    defer fsm_model.deinit();
    var fsm_index = Fsm.init(&fsm_model);
    defer fsm_index.deinit();

    var hdl = try Handle.initWithFsm(&cache, &mgr, &fsm_index, .{});
    defer hdl.deinit();

    var first: [3500]u8 = undefined;
    @memset(&first, 'a');
    var second: [3000]u8 = undefined;
    @memset(&second, 'b');
    _ = try hdl.append(&first);
    const first_id = mgr.first_block_id.?;
    _ = try hdl.append(&second);
    const last_id = mgr.last_block_id.?;
    try std.testing.expect(first_id != last_id);

    try hdl.insertUnordered("fsm");
    try std.testing.expectEqual(@as(u32, 3), try hdl.size());

    var first_page = try hdl.loadPage(first_id);
    defer first_page.deinit();
    var last_page = try hdl.loadPage(last_id);
    defer last_page.deinit();
    try std.testing.expectEqual(@as(usize, 2), try first_page.size());
    try std.testing.expectEqual(@as(usize, 1), try last_page.size());
}
