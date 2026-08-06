const std = @import("std");
const fullaz = @import("fullaz");
const page_chain = fullaz.storage.page_chain;

const page_cache = @import("fullaz").storage.page_cache;
const devices = @import("fullaz").device;
const printer = @import("test_printer");

const extensions = fullaz.page.extensions;

const TestTrait = struct {
    const Self = @This();
    pub const Storage = extern struct {
        fld: [2]u8,
    };

    pub fn format(self: *Storage) void {
        self.fld[0] = 0xAA;
        self.fld[1] = 0xBB;
    }

    pub fn validate(self: *const Storage) bool {
        return self.fld[0] == 0xAA and self.fld[1] == 0xBB;
    }
};

test "PageChain: Create" {
    const FsmAdditional = extensions.Compose(.{ .version = 1, .fields = .{
        extensions.field("fsm", TestTrait),
    } });

    //_ = FsmAdditional;

    const View = page_chain.ViewImpl(u32, u32, FsmAdditional, .little, false);
    const Chunk = View.Chunk;

    var page: [1000]u8 = @splat(0);
    var c = Chunk.init(&page);

    c.formatPage(1, 42, 0, 0);
    try std.testing.expect(c.page_view.header().kind.get() == 1);
    try std.testing.expect(c.getNext() == null);
    try std.testing.expect(c.getPrev() == null);

    printer.print("Header size = {}\n", .{@sizeOf(View.PageHeader)});
    printer.print("Chunk size = {}\n", .{c.data().len});
}

test "PageChain: void additional uses namespaced links" {
    const View = page_chain.ViewImpl(u32, u32, void, .little, false);
    const Additional = View.PageView.Additional;

    var page: [1000]u8 = @splat(0);
    var chunk = View.Chunk.init(&page);
    chunk.formatPage(1, 42, 0, 0);

    try chunk.pageView().validateTyped();
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Additional.Storage, "page_chain"));
    try std.testing.expect(chunk.getNext() == null);
    try std.testing.expect(chunk.getPrev() == null);

    chunk.setNext(17);
    chunk.setPrev(5);
    try std.testing.expectEqual(@as(?u32, 17), chunk.getNext());
    try std.testing.expectEqual(@as(?u32, 5), chunk.getPrev());
}

test "PageChain: user links do not conflict with chain links" {
    const UserAdditional = extensions.Compose(.{ .version = 1, .fields = .{
        extensions.field("links", TestTrait),
    } });
    const View = page_chain.ViewImpl(u32, u32, UserAdditional, .little, false);
    const Additional = View.PageView.Additional;

    var page: [1000]u8 = @splat(0);
    var chunk = View.Chunk.init(&page);
    chunk.formatPage(1, 42, 0, 0);

    const user_links = Additional.field(chunk.pageView().additional(), "links");
    const chain = Additional.field(chunk.pageView().additional(), "page_chain");
    try chunk.pageView().validateTyped();
    try std.testing.expectEqual(@as(u8, 0xAA), user_links.fld[0]);
    try std.testing.expect(chain.links.prev.isMax());
    try std.testing.expect(chain.links.next.isMax());

    chunk.setNext(17);
    chunk.setPrev(5);
    try std.testing.expectEqual(@as(?u32, 17), chunk.getNext());
    try std.testing.expectEqual(@as(?u32, 5), chunk.getPrev());
    try std.testing.expectEqual(@as(u8, 0xAA), user_links.fld[0]);
    try std.testing.expectEqual(@as(u8, 0xBB), user_links.fld[1]);
}

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

test "PageChain: handle" {
    const Subheader = extern struct {
        aa: [4]u8,
    };

    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = page_chain.Handle(Cache, NoneStorageManager, Subheader, .little);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 1000);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = try Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    var c = try hdl.createChunk();
    defer c.deinit();

    try std.testing.expect(try c.getNext() == null);
    try std.testing.expect(try c.getPrev() == null);

    var sh = try c.subheaderMut();
    sh.aa[0] = 0x11;
    sh.aa[1] = 0x22;
    sh.aa[2] = 0x33;
    sh.aa[3] = 0x44;

    printer.print("Subheader = {any}\n", .{sh});
    printer.print("Header Len = {}\n", .{(try c.header()).header_size.get()});
    printer.print("SubHeader Len = {}\n", .{(try c.header()).subheader_size.get()});
    printer.print("Data len = {}\n", .{(try c.getData()).len});
}

test "PageChain: evictChunk relinks neighbors and boundaries" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = page_chain.Handle(Cache, NoneStorageManager, void, .little);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = try Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    var first = try hdl.createChunk();
    defer first.deinit();
    var middle = try hdl.createChunk();
    defer middle.deinit();
    var last = try hdl.createChunk();
    defer last.deinit();

    const first_id = try first.id();
    const middle_id = try middle.id();
    const last_id = try last.id();
    try first.setNext(middle_id);
    try middle.setPrev(first_id);
    try middle.setNext(last_id);
    try last.setPrev(middle_id);
    try mgr.setFirst(first_id);
    try mgr.setLast(last_id);

    try hdl.evictChunk(&middle);
    try std.testing.expectEqual(@as(?u32, last_id), try first.getNext());
    try std.testing.expectEqual(@as(?u32, first_id), try last.getPrev());
    try std.testing.expect((try middle.getPrev()) == null);
    try std.testing.expect((try middle.getNext()) == null);
    try std.testing.expectEqual(@as(?u32, first_id), try mgr.getFirst());
    try std.testing.expectEqual(@as(?u32, last_id), try mgr.getLast());

    try hdl.evictChunk(&first);
    try std.testing.expect((try first.getNext()) == null);
    try std.testing.expect((try last.getPrev()) == null);
    try std.testing.expectEqual(@as(?u32, last_id), try mgr.getFirst());
    try std.testing.expectEqual(@as(?u32, last_id), try mgr.getLast());

    try hdl.evictChunk(&last);
    try std.testing.expect((try last.getPrev()) == null);
    try std.testing.expect((try last.getNext()) == null);
    try std.testing.expect((try mgr.getFirst()) == null);
    try std.testing.expect((try mgr.getLast()) == null);
}

test "PageChain: insert operations preserve order and boundaries" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = page_chain.Handle(Cache, NoneStorageManager, void, .little);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = try Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    var first = try hdl.createChunk();
    defer first.deinit();
    const first_id = try first.id();
    try hdl.insertFirst(&first);
    try std.testing.expectEqual(@as(?u32, first_id), try mgr.getFirst());
    try std.testing.expectEqual(@as(?u32, first_id), try mgr.getLast());

    var last = try hdl.createChunk();
    defer last.deinit();
    const last_id = try last.id();
    try hdl.insertLast(&last);
    try std.testing.expectEqual(@as(?u32, last_id), try first.getNext());
    try std.testing.expectEqual(@as(?u32, first_id), try last.getPrev());
    try std.testing.expectEqual(@as(?u32, first_id), try mgr.getFirst());
    try std.testing.expectEqual(@as(?u32, last_id), try mgr.getLast());

    var before_last = try hdl.createChunk();
    defer before_last.deinit();
    const before_last_id = try before_last.id();
    try hdl.insertBefore(last_id, &before_last);
    try std.testing.expectEqual(@as(?u32, before_last_id), try first.getNext());
    try std.testing.expectEqual(@as(?u32, first_id), try before_last.getPrev());
    try std.testing.expectEqual(@as(?u32, last_id), try before_last.getNext());
    try std.testing.expectEqual(@as(?u32, before_last_id), try last.getPrev());

    var after_before_last = try hdl.createChunk();
    defer after_before_last.deinit();
    const after_before_last_id = try after_before_last.id();
    try hdl.insertAfter(before_last_id, &after_before_last);
    try std.testing.expectEqual(@as(?u32, after_before_last_id), try before_last.getNext());
    try std.testing.expectEqual(@as(?u32, before_last_id), try after_before_last.getPrev());
    try std.testing.expectEqual(@as(?u32, last_id), try after_before_last.getNext());
    try std.testing.expectEqual(@as(?u32, after_before_last_id), try last.getPrev());
    try std.testing.expectEqual(@as(?u32, first_id), try mgr.getFirst());
    try std.testing.expectEqual(@as(?u32, last_id), try mgr.getLast());
}

test "PageChain: iterator traverses linked chunks in both directions" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = page_chain.Handle(Cache, NoneStorageManager, void, .little);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = try Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    var first = try hdl.createChunk();
    defer first.deinit();
    const first_id = try first.id();
    try hdl.insertFirst(&first);

    var middle = try hdl.createChunk();
    defer middle.deinit();
    const middle_id = try middle.id();
    try hdl.insertLast(&middle);

    var last = try hdl.createChunk();
    defer last.deinit();
    const last_id = try last.id();
    try hdl.insertLast(&last);

    var itr = try hdl.iterator();
    defer itr.deinit();
    try std.testing.expectEqual(first_id, (try itr.get()).?.page_id);

    var cloned = (try itr.chunk()).?;
    defer cloned.deinit();
    try std.testing.expectEqual(first_id, try cloned.id());

    try itr.next();
    try std.testing.expectEqual(middle_id, (try itr.get()).?.page_id);
    try itr.next();
    try std.testing.expectEqual(last_id, (try itr.get()).?.page_id);
    try itr.next();
    try std.testing.expect((try itr.get()) == null);

    try itr.prev();
    try std.testing.expectEqual(last_id, (try itr.get()).?.page_id);
    try itr.prev();
    try std.testing.expectEqual(middle_id, (try itr.get()).?.page_id);
    try itr.prev();
    try std.testing.expectEqual(first_id, (try itr.get()).?.page_id);
    try itr.prev();
    try std.testing.expect((try itr.get()) == null);
    try itr.next();
    try std.testing.expectEqual(first_id, (try itr.get()).?.page_id);

    var reverse_itr = try hdl.iteratorFromEnd();
    defer reverse_itr.deinit();
    try std.testing.expectEqual(last_id, (try reverse_itr.get()).?.page_id);
    try reverse_itr.prev();
    try std.testing.expectEqual(middle_id, (try reverse_itr.get()).?.page_id);
    try reverse_itr.prev();
    try std.testing.expectEqual(first_id, (try reverse_itr.get()).?.page_id);
}

test "PageChain: iterator is empty for an empty chain" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = page_chain.Handle(Cache, NoneStorageManager, void, .little);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = try Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    var itr = try hdl.iterator();
    defer itr.deinit();
    try std.testing.expect((try itr.get()) == null);
    try std.testing.expect((try itr.chunk()) == null);
    try itr.next();
    try itr.prev();
    try std.testing.expect((try itr.get()) == null);
}

test "PageChain: remove returns a valid replacement iterator" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = page_chain.Handle(Cache, NoneStorageManager, void, .little);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = try Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    var first = try hdl.createChunk();
    defer first.deinit();
    const first_id = try first.id();
    try hdl.insertFirst(&first);

    var middle = try hdl.createChunk();
    defer middle.deinit();
    const middle_id = try middle.id();
    try hdl.insertLast(&middle);

    var last = try hdl.createChunk();
    defer last.deinit();
    const last_id = try last.id();
    try hdl.insertLast(&last);

    var itr = try hdl.iterator();
    defer itr.deinit();
    try itr.next();
    try std.testing.expectEqual(middle_id, (try itr.get()).?.page_id);

    itr = try hdl.remove(itr);
    try std.testing.expectEqual(last_id, (try itr.get()).?.page_id);
    try std.testing.expectEqual(@as(?u32, last_id), try first.getNext());
    try std.testing.expectEqual(@as(?u32, first_id), try last.getPrev());
    try std.testing.expect((try middle.getNext()) == null);
    try std.testing.expect((try middle.getPrev()) == null);

    itr = try hdl.remove(itr);
    try std.testing.expect((try itr.get()) == null);
    try std.testing.expectEqual(@as(?u32, first_id), try mgr.getFirst());
    try std.testing.expectEqual(@as(?u32, first_id), try mgr.getLast());
    try itr.prev();
    try std.testing.expectEqual(first_id, (try itr.get()).?.page_id);

    itr = try hdl.remove(itr);
    try std.testing.expect((try itr.get()) == null);
    try std.testing.expect((try mgr.getFirst()) == null);
    try std.testing.expect((try mgr.getLast()) == null);
}
