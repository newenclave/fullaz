const std = @import("std");
const fullaz = @import("fullaz");

const slot_chain = fullaz.storage.slot_chain;
const page_cache = fullaz.storage.page_cache;
const devices = fullaz.device;
const fsm = fullaz.storage.fsm;
const extensions = fullaz.page.extensions;

const printer = @import("test_printer");

const NoneStorageManager = struct {
    pub const Self = @This();
    pub const PageId = u32;
    pub const Size = u32;
    pub const Error = error{};

    first_block_id: ?u32 = null,
    last_block_id: ?u32 = null,
    total_size: u32 = 0,

    pub fn destroyPage(_: *@This(), id: PageId) Error!void {
        _ = id;
        // Implement page destruction logic, e.g., add to free list
    }

    pub fn getTotalSize(self: *const Self) Error!Size {
        return self.total_size;
    }

    pub fn setTotalSize(self: *Self, size: Size) Error!void {
        self.total_size = size;
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

const FsmStorageManager = struct {
    pub const PageId = u32;
    pub const Size = u32;
    pub const Error = error{};

    first_block_id: ?u32 = null,
    last_block_id: ?u32 = null,
    total_size: u32 = 0,
    fsm_roots: [256]?u32 = .{null} ** 256,

    pub fn destroyPage(_: *@This(), _: PageId) Error!void {}

    pub fn getTotalSize(self: *const @This()) Error!Size {
        return self.total_size;
    }

    pub fn setTotalSize(self: *@This(), size: Size) Error!void {
        self.total_size = size;
    }

    pub fn getFirst(self: *const @This()) Error!?PageId {
        return self.first_block_id;
    }

    pub fn getLast(self: *const @This()) Error!?PageId {
        return self.last_block_id;
    }

    pub fn setFirst(self: *@This(), page_id: ?PageId) Error!void {
        self.first_block_id = page_id;
    }

    pub fn setLast(self: *@This(), page_id: ?PageId) Error!void {
        self.last_block_id = page_id;
    }

    pub fn getSizeClassRoot(self: *const @This(), class: u16) Error!?PageId {
        return self.fsm_roots[class];
    }

    pub fn setSizeClassRoot(self: *@This(), class: u16, root: ?PageId) Error!void {
        self.fsm_roots[class] = root;
    }
};

const FsmSizePolicy = struct {
    pub const SizeClass = u16;

    pub fn getSizeClass(_: *const @This(), size: SizeClass) !SizeClass {
        return size >> 8;
    }

    pub fn count(_: *const @This()) usize {
        return 256;
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

test "SlotChain: pending removal keeps marked data alive" {
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
    _ = try hdl.append("first");
    _ = try hdl.append("second");

    var itr = (try hdl.iterator()).?;
    const first = (try itr.next()).?;
    var pending = try itr.markForRemoval();
    defer pending.deinit();
    try std.testing.expectEqualStrings("first", try pending.value());

    try std.testing.expectEqualStrings("second", (try itr.next()).?.value);
    itr.deinit();

    try std.testing.expectEqualStrings("first", first.value);
    try std.testing.expectEqualStrings("first", try pending.value());
}

test "SlotChain: pending removal cleans one slot idempotently" {
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
    _ = try hdl.append("first");
    _ = try hdl.append("second");
    _ = try hdl.append("third");

    var itr = (try hdl.iterator()).?;
    defer itr.deinit();
    _ = (try itr.next()).?;
    var pending = try itr.markForRemoval();
    defer pending.deinit();

    try std.testing.expect(try pending.clean());
    try std.testing.expect(!(try pending.clean()));
    try std.testing.expectError(error.InvalidIterator, pending.value());

    var page = try hdl.loadPage(mgr.first_block_id.?);
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 2), try page.size());
    try std.testing.expect(!try page.isTombstone(0));

    var survivors = (try hdl.iterator()).?;
    defer survivors.deinit();
    const second = (try survivors.next()).?;
    try std.testing.expectEqualStrings("second", second.value);
    try std.testing.expectEqual(@as(usize, 0), second.pos);
    const third = (try survivors.next()).?;
    try std.testing.expectEqualStrings("third", third.value);
    try std.testing.expectEqual(@as(usize, 1), third.pos);
}

test "SlotChain: pending removal updates FSM and total size" {
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

    var value: [3500]u8 = undefined;
    @memset(&value, 'x');
    const page_id = try hdl.append(&value);
    try std.testing.expect((try hdl.findFreeSlot(700)) == null);

    var itr = (try hdl.iterator()).?;
    defer itr.deinit();
    _ = (try itr.next()).?;
    var pending = try itr.markForRemoval();
    defer pending.deinit();

    try std.testing.expect(try pending.clean());
    try std.testing.expectEqual(@as(usize, 0), try hdl.size());
    try std.testing.expectEqual(@as(?u32, page_id), try hdl.findFreeSlot(700));
}

test "SlotChain: pending removal rejects iterator boundary states" {
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
    _ = try hdl.append("only");

    var itr = (try hdl.iterator()).?;
    defer itr.deinit();
    try std.testing.expectError(error.InvalidIterator, itr.markForRemoval());

    _ = (try itr.next()).?;
    try std.testing.expect((try itr.next()) == null);
    try std.testing.expectError(error.InvalidIterator, itr.markForRemoval());
}

test "SlotChain: paged FSM stores its location in the effective header" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    const LocationTrait = fsm.location.Trait(u32, u16, .little);
    const UserAdditional = extensions.Compose(.{
        .version = 2,
        .fields = .{
            extensions.field("fsm", LocationTrait),
        },
    });
    const SlotView = slot_chain.ViewImpl(u32, u16, UserAdditional, .little, false);
    const LocationAccessor = fsm.HeaderLocationAccessor(
        u32,
        u16,
        .little,
        SlotView.Additional,
        "fsm",
    );
    const FsmModel = fsm.models.paged.slab.Model(
        Cache,
        FsmStorageManager,
        FsmSizePolicy,
        LocationAccessor,
    );
    const Fsm = fsm.Fsm(FsmModel);
    const Handle = slot_chain.HandleImpl(
        Cache,
        FsmStorageManager,
        UserAdditional,
        void,
        Fsm,
        .little,
    );

    var storage = FsmStorageManager{};
    var dev = try Device.init(std.testing.allocator, 4096);
    defer dev.deinit();
    var cache = try Cache.init(&dev, std.testing.allocator, 32);
    defer cache.deinit();
    var fsm_model = FsmModel.init(
        &cache,
        &storage,
        FsmSizePolicy{},
        .{ .page_kind = 0x62 },
    );
    var fsm_index = Fsm.init(&fsm_model);
    defer fsm_index.deinit();

    var hdl = try Handle.initWithFsm(
        &cache,
        &storage,
        &fsm_index,
        .{},
    );
    defer hdl.deinit();

    var value: [3500]u8 = undefined;
    @memset(&value, 'x');
    const page_id = try hdl.append(&value);
    try std.testing.expectEqual(@as(?u32, page_id), try fsm_index.find(1));
    try std.testing.expectEqual(@as(?u32, page_id), try storage.getFirst());
    try std.testing.expectEqual(@as(?u32, page_id), try storage.getLast());
    {
        var page = try cache.fetch(page_id);
        defer page.deinit();
        try std.testing.expect((try LocationAccessor.read(try page.getData())) != null);
    }

    var itr = (try hdl.iterator()).?;
    defer itr.deinit();
    _ = (try itr.next()).?;
    var pending = try itr.markForRemoval();
    defer pending.deinit();
    try std.testing.expect(try pending.clean());

    try std.testing.expectEqual(@as(usize, 0), try hdl.size());
    try std.testing.expectEqual(@as(?u32, page_id), try fsm_index.find(700));
    try std.testing.expectEqual(@as(?u32, page_id), try storage.getFirst());
    try std.testing.expectEqual(@as(?u32, page_id), try storage.getLast());
    {
        var page = try cache.fetch(page_id);
        defer page.deinit();
        try std.testing.expect((try LocationAccessor.read(try page.getData())) != null);
    }
}
