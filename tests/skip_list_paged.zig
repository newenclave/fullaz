const std = @import("std");
const skip_list = @import("fullaz").skip_list;
const algorithm = @import("fullaz").core.algorithm;

const PageCacheT = @import("fullaz").storage.page_cache.PageCache;
const device = @import("fullaz").device;
const fsm = @import("fullaz").storage.fsm;

const ModelType = skip_list.models.Paged;
const SkipList = skip_list.List;
const View = skip_list.models.paged.View;

const FsmMem = fsm.models.Memory(u32, u16);
const Fsm = fsm.Fsm2(FsmMem);

const interfaces = skip_list.models.interfaces;

fn getNowTimestamp() u64 {
    const io = std.testing.io;
    const timestamp = std.Io.Clock.real.now(io);
    const millis = @abs(timestamp.toMilliseconds());
    return millis;
}

fn keyCmp(ctx: anytype, k1: []const u8, k2: []const u8) algorithm.Order {
    return algorithm.cmpSlices(u8, k1, k2, algorithm.CmpNum(u8).asc, ctx) catch .gt;
}

const PidType = struct {
    page_id: u32 = 0,
    slot_id: usize = 0,
};

const NoneStorageManager = struct {
    pub const Self = @This();

    pub const PageId = PidType;
    pub const Error = error{};
    roots: [32]?PidType = .{null} ** 32,

    pub fn getRoot(self: *const Self, level: usize) ?PidType {
        if (level >= self.roots.len) {
            @panic("Level exceeds maximum supported levels");
        }
        return self.roots[level];
    }

    pub fn setRoot(self: *Self, level: usize, root: ?PidType) Error!void {
        if (level >= self.roots.len) {
            @panic("Level exceeds maximum supported levels");
        }
        self.roots[level] = root;
    }

    pub fn destroyPage(_: *Self, id: PageId) Error!void {
        _ = id;
        // Implement page destruction logic, e.g., add to free list
    }
};

test "SkipList paged: page and view" {
    var buf: [4096]u8 = .{0} ** 4096;
    var view = View(u32, u16, std.builtin.Endian.little, false).init(buf[0..]);
    try view.formatPage(42, 1234, 64);

    const hdr = view.page_view.header();
    std.debug.print("Subheader kind: {d}\n", .{hdr.kind.get()});
    const slots = try view.slotsDir();

    std.debug.print("Number of slots: {d}\n", .{slots.capacityFor(16)});
}

test "SkipList paged: create and load nodes" {
    const allocator = std.testing.allocator;

    const Device = device.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);

    const Model = ModelType(PageCache, NoneStorageManager, Fsm, keyCmp, void);

    var dev = try Device.init(allocator, 4096);
    defer dev.deinit();
    var fsm_mem = try FsmMem.init(allocator);
    defer fsm_mem.deinit();
    var fsm_inst = Fsm.init(&fsm_mem);
    defer fsm_inst.deinit();

    var cache = try PageCache.init(&dev, allocator, 16);
    defer cache.deinit();

    var mgr = NoneStorageManager{};

    var prng: std.Random.DefaultPrng = .init(getNowTimestamp());
    const rand = prng.random();

    var model = Model.init(&cache, &mgr, &fsm_inst, .{
        .max_level = 1,
        .key_len = 4,
        .value_len = 4,
        .node_page_kind = 42,
    }, {}, rand);
    defer model.deinit();
}

test "SkipList paged: create slot, work with the slot" {
    var buf: [4096]u8 = .{0} ** 4096;
    const ViewT = View(u32, u16, std.builtin.Endian.little, false);
    const SlotWrapper = ViewT.SlotWrapper;

    _ = SlotWrapper;

    var view = ViewT.init(buf[0..]);
    try view.formatPage(42, 1234, 64);

    var slotBody: [256]u8 = .{0} ** 256;
    var slot = try view.createSlot(slotBody[0..], 4, 4, 7);

    try std.testing.expectEqual(4, slot.header().key_len.get());
    try std.testing.expectEqual(4, slot.header().value_len.get());
    try std.testing.expectEqual(7, slot.header().level);

    try view.insert(0, slot.body());
    const ss = try view.get(0);

    try std.testing.expectEqual(4, ss.header().key_len.get());
    try std.testing.expectEqual(4, ss.header().value_len.get());
    try std.testing.expectEqual(7, ss.header().level);

    try std.testing.expectEqual(slot.body().len, ss.body().len);
    try std.testing.expect(keyCmp({}, slot.key, ss.key) == .eq);

    std.debug.print("Can insert: {any}\n", .{try view.canInsert(0, slot.key, slot.value, slot.header().level)});
    std.debug.print("Can insert: {any}\n", .{try view.canInsertSize(0, 4096)});
}

test "SkipList paged: interfaces" {
    //const allocator = std.testing.allocator;
    const Device = device.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const Model = ModelType(PageCache, NoneStorageManager, Fsm, keyCmp, void);

    comptime interfaces.assertPath(Model.Accessor.Path);
}

test "SkipList paged: createNode allocates a slot + tracks the page; destroy frees it" {
    const allocator = std.testing.allocator;
    const Device = device.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const Model = ModelType(PageCache, NoneStorageManager, Fsm, keyCmp, void);

    var dev = try Device.init(allocator, 4096);
    defer dev.deinit();
    var cache = try PageCache.init(&dev, allocator, 16);
    defer cache.deinit();
    var mgr = NoneStorageManager{};
    var fsm_mem = try FsmMem.init(allocator);
    defer fsm_mem.deinit();
    var fsm_inst = Fsm.init(&fsm_mem);
    defer fsm_inst.deinit();

    var prng: std.Random.DefaultPrng = .init(getNowTimestamp());
    const rand = prng.random();

    var model = Model.init(&cache, &mgr, &fsm_inst, .{
        .max_level = 4,
        .key_len = 4,
        .value_len = 4,
    }, {}, rand);
    defer model.deinit();

    var node = try model.accessor.createNode("AAAA", "BBBB");
    const ref = node.id();

    // the data page now carries our slot (inspect via a read-only View)
    var used_after_create: usize = undefined;
    {
        var ph = try cache.fetch(ref.page_id);
        defer ph.deinit();
        const v = View(u32, u16, std.builtin.Endian.little, true).init(try ph.getData());
        try std.testing.expectEqual(@as(usize, 1), try v.entries());
        const sw = try v.get(ref.slot_id);
        try std.testing.expect(std.mem.eql(u8, sw.key, "AAAA"));
        try std.testing.expect(std.mem.eql(u8, sw.value, "BBBB"));
        used_after_create = try (try v.slotsDir()).usedSpace();
    }

    // the page is registered in the fsm (it still has room)
    try std.testing.expectEqual(@as(?u32, ref.page_id), try fsm_inst.find(1));

    // deinit = release the handle only (page + slot stay)
    model.accessor.deinitNode(&node);

    // destroy = free the slot and return the page to the fsm
    model.accessor.destroy(ref);
    {
        var ph = try cache.fetch(ref.page_id);
        defer ph.deinit();
        const v = View(u32, u16, std.builtin.Endian.little, true).init(try ph.getData());
        const used_after_destroy = try (try v.slotsDir()).usedSpace();
        try std.testing.expect(used_after_destroy < used_after_create); // slot reclaimed
    }
    // page is still tracked by the fsm (returned, not dropped)
    try std.testing.expectEqual(@as(?u32, ref.page_id), try fsm_inst.find(1));
}
