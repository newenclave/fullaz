const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");
const page_chain = fullaz.storage.page_chain;

const page_cache = @import("fullaz").storage.page_cache;
const devices = @import("fullaz").device;
const printer = @import("test_printer");

const extensions = fullaz.page.extensions;

test "PageChain: destroyChunk releases its page before reclamation" {
    const Device = devices.MemoryBlock(u32);
    const RawCache = page_cache.PageCache(Device);
    const Cache = fullaz_db.MemoryReclaimingCache(RawCache);
    const Manager = struct {
        pub const PageId = u32;
        pub const Size = u32;
        pub const Error = Cache.Error;

        cache: *Cache,

        pub fn destroyPage(self: *@This(), page_id: PageId) Error!void {
            return self.cache.free(page_id);
        }
    };
    const Chain = page_chain.ForwardHandle(Cache, Manager, void, .little);

    var device = try Device.init(std.testing.allocator, 256);
    defer device.deinit();
    var raw_cache = try RawCache.init(&device, std.testing.allocator, 2);
    defer raw_cache.deinit();
    var cache = Cache.init(std.testing.allocator, &raw_cache);
    defer cache.deinit();
    var manager = Manager{ .cache = &cache };
    var chain = try Chain.init(&cache, &manager, .{ .chunk_page_kind = 77 });
    defer chain.deinit();

    var chunk = try chain.createChunk();
    const page_id = try chunk.id();
    try chain.destroyChunk(chunk);

    try std.testing.expectError(error.PageNotAllocated, cache.fetch(page_id));
}

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

    const View = page_chain.ViewImpl(
        u32,
        u32,
        FsmAdditional,
        false,
        .little,
        false,
    );
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
    const View = page_chain.ViewImpl(u32, u32, void, false, .little, false);
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

test "PageChain: forward view stores only next links" {
    const View = page_chain.ForwardView(u32, u32, .little, false);
    const Additional = View.PageView.Additional;

    comptime {
        if (@hasDecl(View.Chunk, "getPrev") or @hasDecl(View.Chunk, "setPrev")) {
            @compileError("forward page-chain chunks must not expose backward links");
        }
    }

    var page: [1000]u8 = @splat(0);
    var chunk = View.Chunk.init(&page);
    chunk.formatPage(1, 42, 0, 0);

    const chain = Additional.field(chunk.pageView().additional(), "page_chain");
    try chunk.pageView().validateTyped();
    try std.testing.expectEqual(@sizeOf(u32), @sizeOf(@TypeOf(chain.links)));
    try std.testing.expectEqual(@as(?u32, null), chunk.getNext());

    chunk.setNext(17);
    try std.testing.expectEqual(@as(?u32, 17), chunk.getNext());
}

test "PageChain: user links do not conflict with chain links" {
    const UserAdditional = extensions.Compose(.{ .version = 1, .fields = .{
        extensions.field("links", TestTrait),
    } });
    const View = page_chain.ViewImpl(u32, u32, UserAdditional, false, .little, false);
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

const ForwardOnlyStorageManager = struct {
    pub const Self = @This();
    pub const PageId = u32;
    pub const Size = u32;
    pub const Error = error{};

    first_block_id: ?u32 = null,
    destroyed_count: usize = 0,

    pub fn destroyPage(self: *Self, id: PageId) Error!void {
        _ = id;
        self.destroyed_count += 1;
    }

    pub fn getFirst(self: *const Self) Error!?PageId {
        return self.first_block_id;
    }

    pub fn setFirst(self: *Self, page_id: ?PageId) Error!void {
        self.first_block_id = page_id;
    }
};

const RootOnlyBidirectionalStorageManager = struct {
    pub const Self = @This();
    pub const PageId = u32;
    pub const Size = u32;
    pub const Error = error{};

    first_block_id: ?u32 = null,
    destroyed_count: usize = 0,

    pub fn destroyPage(self: *Self, id: PageId) Error!void {
        _ = id;
        self.destroyed_count += 1;
    }

    pub fn getFirst(self: *const Self) Error!?PageId {
        return self.first_block_id;
    }

    pub fn setFirst(self: *Self, page_id: ?PageId) Error!void {
        self.first_block_id = page_id;
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
    printer.print("Data len = {}\n", .{(try c.data()).len});
}

test "PageChain: loadChunk rejects a plain page with the same kind" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = page_chain.Handle(Cache, NoneStorageManager, void, .little);
    const PlainView = fullaz.page.header.View(u32, u16, .little, false);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = try Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    var page = try cache.create();
    defer page.deinit();
    const pid = try page.pid();
    var plain = PlainView.init(try page.dataMut());
    plain.formatPage(0x51, pid, 0, 0);

    try std.testing.expectError(error.InvalidHeaderSize, hdl.loadChunk(pid));
}

test "PageChain: bidirectional loader rejects a mismatched self pid" {
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

    var chunk = try hdl.createChunk();
    defer chunk.deinit();
    const pid = try chunk.id();
    (try chunk.headerMut()).self_pid.set(pid + 1);

    const available_before = cache.availableFrames();
    try std.testing.expectError(error.BadData, hdl.loadChunk(pid));
    try std.testing.expectEqual(available_before, cache.availableFrames());
}

test "PageChain: forward loader rejects a mismatched self pid" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = page_chain.ForwardHandle(Cache, NoneStorageManager, void, .little);

    var mgr = NoneStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();
    var hdl = try Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    var chunk = try hdl.createChunk();
    defer chunk.deinit();
    const pid = try chunk.id();
    (try chunk.headerMut()).self_pid.set(pid + 1);

    const available_before = cache.availableFrames();
    try std.testing.expectError(error.BadData, hdl.loadChunk(pid));
    try std.testing.expectEqual(available_before, cache.availableFrames());
}

test "PageChain: iterator rejects a linked page with another kind" {
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

    var other = try hdl.createChunk();
    defer other.deinit();
    const other_id = try other.id();
    (try other.headerMut()).kind.set(0x52);
    try first.setNext(other_id);

    var itr = try hdl.iterator();
    defer itr.deinit();
    try std.testing.expectEqual(first_id, (try itr.get()).?.page_id);
    try std.testing.expectError(error.BadType, itr.next());
    try std.testing.expectEqual(first_id, (try itr.get()).?.page_id);
}

test "PageChain: forward handle maintains an optional tail" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = page_chain.ForwardHandle(Cache, NoneStorageManager, void, .little);

    comptime {
        if (@hasDecl(Handle.Chunk, "getPrev") or @hasDecl(Handle.Chunk, "setPrev")) {
            @compileError("forward page-chain handles must not expose backward links");
        }
    }

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

    var after = try hdl.createChunk();
    defer after.deinit();
    const after_id = try after.id();
    try hdl.insertAfter(first_id, &after);
    try std.testing.expectEqual(@as(?u32, after_id), try first.getNext());
    try std.testing.expectEqual(@as(?u32, after_id), try mgr.getLast());

    var new_first = try hdl.createChunk();
    defer new_first.deinit();
    const new_first_id = try new_first.id();
    try hdl.insertFirst(&new_first);
    try std.testing.expectEqual(@as(?u32, new_first_id), try mgr.getFirst());
    try std.testing.expectEqual(@as(?u32, first_id), try new_first.getNext());
    try std.testing.expectEqual(@as(?u32, after_id), try mgr.getLast());
}

test "PageChain: forward handle removes chunks with a root-only manager" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = page_chain.ForwardHandle(Cache, ForwardOnlyStorageManager, void, .little);

    comptime {
        if (@hasDecl(ForwardOnlyStorageManager, "getLast") or @hasDecl(ForwardOnlyStorageManager, "setLast")) {
            @compileError("forward-only test manager must not have tail state");
        }
    }

    var mgr = ForwardOnlyStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 8);
    defer cache.deinit();

    var hdl = try Handle.init(&cache, &mgr, .{});
    defer hdl.deinit();

    var first = try hdl.createChunk();
    defer first.deinit();
    const first_id = try first.id();
    try hdl.insertLast(&first);

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
    try std.testing.expect((try middle.getNext()) == null);

    var root_itr = try hdl.iterator();
    defer root_itr.deinit();
    try std.testing.expectEqual(first_id, (try root_itr.get()).?.page_id);
    root_itr = try hdl.remove(root_itr);
    try std.testing.expectEqual(last_id, (try root_itr.get()).?.page_id);
    try std.testing.expectEqual(@as(?u32, last_id), try mgr.getFirst());

    root_itr = try hdl.remove(root_itr);
    try std.testing.expect((try root_itr.get()) == null);
    try std.testing.expect((try mgr.getFirst()) == null);

    var by_id = try hdl.createChunk();
    defer by_id.deinit();
    const by_id_pid = try by_id.id();
    try hdl.insertFirst(&by_id);
    var by_id_last = try hdl.createChunk();
    defer by_id_last.deinit();
    const by_id_last_pid = try by_id_last.id();
    try hdl.insertLast(&by_id_last);
    try std.testing.expect(try hdl.removeById(by_id_last_pid));
    try std.testing.expectEqual(@as(?u32, by_id_pid), try mgr.getFirst());
    try std.testing.expect((try by_id.getNext()) == null);
    try std.testing.expect(!(try hdl.removeById(by_id_last_pid)));
    try std.testing.expectEqual(@as(usize, 4), mgr.destroyed_count);
}

test "PageChain: bidirectional handle works with a root-only manager" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = page_chain.BidirectionalHandle(
        Cache,
        RootOnlyBidirectionalStorageManager,
        void,
        .little,
    );

    comptime {
        if (@hasDecl(RootOnlyBidirectionalStorageManager, "getLast") or
            @hasDecl(RootOnlyBidirectionalStorageManager, "setLast"))
        {
            @compileError("root-only bidirectional test manager must not have tail state");
        }
    }

    var mgr = RootOnlyBidirectionalStorageManager{};
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

    try std.testing.expectEqual(@as(?u32, middle_id), try first.getNext());
    try std.testing.expect((try first.getPrev()) == null);
    try std.testing.expectEqual(@as(?u32, first_id), try middle.getPrev());
    try std.testing.expectEqual(@as(?u32, last_id), try middle.getNext());
    try std.testing.expectEqual(@as(?u32, middle_id), try last.getPrev());
    try std.testing.expect((try last.getNext()) == null);

    var reverse_itr = try hdl.iteratorFromEnd();
    defer reverse_itr.deinit();
    try std.testing.expectEqual(last_id, (try reverse_itr.get()).?.page_id);
    try reverse_itr.prev();
    try std.testing.expectEqual(middle_id, (try reverse_itr.get()).?.page_id);

    try hdl.evictChunk(&middle);
    try std.testing.expectEqual(@as(?u32, last_id), try first.getNext());
    try std.testing.expectEqual(@as(?u32, first_id), try last.getPrev());

    try hdl.evictChunk(&last);
    try std.testing.expect((try first.getNext()) == null);

    try hdl.evictChunk(&first);
    try std.testing.expect((try mgr.getFirst()) == null);
}

test "PageChain: bidirectional remove works with a root-only manager" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const Handle = page_chain.BidirectionalHandle(
        Cache,
        RootOnlyBidirectionalStorageManager,
        void,
        .little,
    );

    var mgr = RootOnlyBidirectionalStorageManager{};
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
    try std.testing.expect((try middle.getPrev()) == null);
    try std.testing.expect((try middle.getNext()) == null);
    try std.testing.expectEqual(@as(usize, 1), mgr.destroyed_count);

    itr = try hdl.remove(itr);
    try std.testing.expect((try itr.get()) == null);
    try itr.prev();
    try std.testing.expectEqual(first_id, (try itr.get()).?.page_id);
    try std.testing.expect((try first.getNext()) == null);
    try std.testing.expectEqual(@as(usize, 2), mgr.destroyed_count);

    itr = try hdl.remove(itr);
    try std.testing.expect((try itr.get()) == null);
    try std.testing.expect((try mgr.getFirst()) == null);
    try std.testing.expectEqual(@as(usize, 3), mgr.destroyed_count);
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

    var cloned = (try itr.cloneChunk()).?;
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
    try std.testing.expect((try itr.cloneChunk()) == null);
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
