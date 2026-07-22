const std = @import("std");
const skip_list = @import("fullaz").skip_list;
const algorithm = @import("fullaz").core.algorithm;

const PageCacheT = @import("fullaz").storage.page_cache.PageCache;
const device = @import("fullaz").device;
const fsm = @import("fullaz").storage.fsm;

const ModelType = skip_list.models.Paged;
const MemoryModel = skip_list.models.Memory;
const SkipList = skip_list.List;
const View = skip_list.models.paged.View;

const FsmMem = fsm.models.Memory(u32, u16);
const Fsm = fsm.Fsm2(FsmMem);

const interfaces = skip_list.models.interfaces;

var globalTestStart: u64 = 0;
var globalTag: []const u8 = "";

fn getNowTimestamp() u64 {
    const io = std.testing.io;
    const timestamp = std.Io.Clock.real.now(io);
    const millis = @abs(timestamp.toMilliseconds());
    return millis;
}

fn beforeTest(tag: []const u8) void {
    globalTestStart = getNowTimestamp();
    globalTag = tag;
}

fn timestampPrint(comptime name: []const u8, params: anytype) void {
    const io = std.testing.io;
    const timestamp = std.Io.Clock.real.now(io);
    const millis = @abs(timestamp.toMilliseconds()) - globalTestStart;
    const hours = millis / (1000 * 60 * 60);
    const mins = (millis / (1000 * 60)) % 60;
    const seconds = (millis / 1000) % 60;

    std.debug.print("{d:0>2}:{:0>2}:{:0>2}.{d:0>4} [{s}]: ", .{ hours, mins, seconds, @mod(millis, 1000), globalTag });
    std.debug.print(name, params);
}

fn keyCmp(ctx: anytype, k1: []const u8, k2: []const u8) std.math.Order {
    const res = algorithm.cmpSlices(u8, k1, k2, algorithm.CmpNum(u8).asc, ctx) catch .gt;
    switch (res) {
        .lt => return .lt,
        .gt => return .gt,
        .eq => return .eq,
        .unordered => return .gt, // treat unordered as greater
    }
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

    pub fn getRoot(self: *const Self, level: usize) Error!?PidType {
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
    }, {}, rand, std.testing.allocator);
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

    const ts = getNowTimestamp();
    std.debug.print("Test timestamp: {d}\n", .{ts});

    var prng: std.Random.DefaultPrng = .init(ts);
    const rand = prng.random();

    var model = Model.init(&cache, &mgr, &fsm_inst, .{
        .max_level = 4,
        .key_len = 4,
        .value_len = 4,
    }, {}, rand, allocator);
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

    // read the node back through its own accessors (C4)
    const got_key = try node.getKey();
    const got_value = try node.getValue();

    try std.testing.expect(std.mem.eql(u8, got_key, "AAAA"));
    try std.testing.expect(std.mem.eql(u8, got_value, "BBBB"));
    {
        const lvl = try node.getLevel();
        std.debug.print("Node level: {d}\n", .{lvl});
        try std.testing.expect(lvl >= 1 and lvl <= 4); // max_level = 4
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

fn keyDumper(value: []const u8) void {
    const d: u32 = std.mem.readInt(u32, value[0..4], .big);
    std.debug.print("{any}; ", .{d});
}

fn valueDumper(_: []const u8) void {
    //std.debug.print("={d}; ", .{value.*});
}

test "SkipList paged: node next/prev links round-trip per level" {
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
    }, {}, rand, allocator);
    defer model.deinit();

    // two real nodes on the page; n2 is the link target (its slot_id is non-zero)
    var n1 = try model.accessor.createNode("K1AA", "V1BB");
    defer model.accessor.deinitNode(&n1);
    var n2 = try model.accessor.createNode("K2AA", "V2BB");
    defer model.accessor.deinitNode(&n2);

    const id2 = n2.id();

    // a freshly created node has every level's next/prev formatted to null
    const nlevels = try n1.getLevel();
    try std.testing.expect(nlevels >= 1);
    {
        var lvl: usize = 0;
        while (lvl < nlevels) : (lvl += 1) {
            try std.testing.expect((try n1.getNext(lvl)) == null);
            try std.testing.expect((try n1.getPrev(lvl)) == null);
        }
    }

    // out-of-range levels are rejected on both read and write
    try std.testing.expectError(error.OutOfBounds, n1.getNext(nlevels));
    try std.testing.expectError(error.OutOfBounds, n1.getPrev(nlevels));
    try std.testing.expectError(error.OutOfBounds, n1.setNext(nlevels, id2));

    const top = nlevels - 1;

    // set next at the top level -> reads back the same pid; prev stays null (fields are independent)
    try n1.setNext(top, id2);
    {
        const got = (try n1.getNext(top)).?;
        try std.testing.expectEqual(id2.page_id, got.page_id);
        try std.testing.expectEqual(id2.slot_id, got.slot_id);
    }
    try std.testing.expect((try n1.getPrev(top)) == null);

    // set prev at the top level -> reads back; next link is unchanged
    try n1.setPrev(top, id2);
    {
        const got = (try n1.getPrev(top)).?;
        try std.testing.expectEqual(id2.page_id, got.page_id);
        try std.testing.expectEqual(id2.slot_id, got.slot_id);
    }
    try std.testing.expect((try n1.getNext(top)) != null);

    // levels are indexed independently: level 0 is untouched by writes at the top level
    if (nlevels > 1) {
        try std.testing.expect((try n1.getNext(0)) == null);
        try n1.setNext(0, id2);
        try std.testing.expect((try n1.getNext(0)) != null);
        try std.testing.expect((try n1.getNext(top)) != null); // top link survives
    }

    // clearing writes null back through the max sentinel
    try n1.setNext(top, null);
    try n1.setPrev(top, null);
    try std.testing.expect((try n1.getNext(top)) == null);
    try std.testing.expect((try n1.getPrev(top)) == null);
}

test "SkipList paged: View.compact reclaims a freed hole and preserves slot ids" {
    var buf: [1024]u8 = .{0} ** 1024;
    const ViewT = View(u32, u16, std.builtin.Endian.little, false);
    var v = ViewT.init(buf[0..]);
    try v.formatPage(1, 7, 0);

    // four level-0 slots with distinct keys at indices 0..3
    const keys = [_][]const u8{ "AAAA", "BBBB", "CCCC", "DDDD" };
    for (keys, 0..) |k, i| {
        var scratch: [64]u8 = undefined;
        const s = try v.createSlot(scratch[0..], 4, 4, 0);
        @memcpy(s.key, k);
        @memcpy(s.value, "vvvv");
        for (s.levels) |*lr| lr.format();
        try v.insert(i, s.body());
    }
    try std.testing.expectEqual(@as(usize, 4), try v.entries());

    // free a middle slot -> a fragmented hole above free_end (only compaction reclaims it)
    {
        var sd = try v.slotsDirMut();
        try sd.free(1);
    }
    const contiguous_pre = (try v.slotsDir()).availableSpace();

    try v.compact(null);

    // the hole is now folded into the contiguous free region
    try std.testing.expect((try v.slotsDir()).availableSpace() > contiguous_pre);

    // slot ids are stable: surviving slots keep index -> data (what skip-list links rely on)
    try std.testing.expect(std.mem.eql(u8, (try v.get(0)).key, "AAAA"));
    try std.testing.expect(std.mem.eql(u8, (try v.get(2)).key, "CCCC"));
    try std.testing.expect(std.mem.eql(u8, (try v.get(3)).key, "DDDD"));
    // free() (not remove()) keeps the directory length
    try std.testing.expectEqual(@as(usize, 4), try v.entries());
}

test "SkipList paged: checkCompactPage compacts a fragmented page so a larger slot fits" {
    const allocator = std.testing.allocator;
    const Device = device.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const Model = ModelType(PageCache, NoneStorageManager, Fsm, keyCmp, void);

    var dev = try Device.init(allocator, 1024); // small page -> easy to fill and fragment
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
    }, {}, rand, allocator);
    defer model.deinit();

    const ViewT = View(u32, u16, std.builtin.Endian.little, false);

    // a real, formatted node page we fill by hand
    var ph = try cache.create();
    defer ph.deinit();
    {
        var v = ViewT.init(try ph.getDataMut());
        try v.formatPage(1, try ph.pid(), 0);
    }

    // fill with small (level 0) slots until the contiguous free region is exhausted
    var count: usize = 0;
    while (true) {
        var v = ViewT.init(try ph.getDataMut());
        const pos = try v.entries();
        if ((try v.canInsert(pos, "smal", "vvvv", 0)) != .enough) break;
        var scratch: [128]u8 = undefined;
        const s = try v.createSlot(scratch[0..], 4, 4, 0);
        @memcpy(s.key, "smal");
        @memcpy(s.value, "vvvv");
        for (s.levels) |*lr| lr.format();
        try v.insert(pos, s.body());
        count += 1;
    }
    try std.testing.expect(count >= 4);

    // mark the last slot (never freed) so we can prove its index survives compaction
    const survivor = count - 1;
    {
        var v = ViewT.init(try ph.getDataMut());
        const sw = try v.getMut(survivor);
        @memcpy(sw.key, "LAST");
    }

    // free front slots until inserting a big (level 4) slot needs compaction to fit
    var reached = false;
    var f: usize = 0;
    while (f < survivor) : (f += 1) {
        const vc = ViewT.init(try ph.getDataMut());
        const pos = try vc.entries();
        if ((try vc.canInsert(pos, "bigk", "vvvv", 4)) == .need_compact) {
            reached = true;
            break;
        }
        var vm = ViewT.init(try ph.getDataMut());
        var sd = try vm.slotsDirMut();
        try sd.free(f);
    }
    try std.testing.expect(reached); // we actually constructed the .need_compact state

    // the user's method: sees .need_compact, compacts (via a temp page), reports it now fits
    const fits = try model.accessor.checkCompactPage(&ph, "bigk", "vvvv", 4);
    try std.testing.expect(fits);

    // post: the big slot fits contiguously now, and the survivor kept its index -> data
    {
        const v = ViewT.init(try ph.getDataMut());
        const pos = try v.entries();
        try std.testing.expect((try v.canInsert(pos, "bigk", "vvvv", 4)) == .enough);
        try std.testing.expect(std.mem.eql(u8, (try v.get(survivor)).key, "LAST"));
    }
}

test "SkipList paged: iterator remove test" {
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
    }, {}, rand, allocator);
    defer model.deinit();

    const SL = SkipList(Model);
    var sl = SL.init(&model);

    var desiderKeys = try std.ArrayList(u32).initCapacity(allocator, 100);
    defer desiderKeys.deinit(allocator);

    timestampPrint("Inserting keys...\n", .{});
    for (0..1000) |k| {
        const next = @as(u32, (@as(u32, @intCast(k)) + 1)) * 10;
        try desiderKeys.append(allocator, next);
        var kv: [@sizeOf(u32)]u8 = undefined;
        std.mem.writeInt(u32, kv[0..], next, .big);
        try sl.insert(&kv, &kv);
    }

    timestampPrint("Iterating keys...\n", .{});
    var count: usize = 0;
    var expected_key: u32 = 0;

    const half = desiderKeys.items.len / 2;

    timestampPrint("start removing the keys...\n", .{});

    for (0..half) |id| {
        const next = @as(u32, (@as(u32, @intCast(id * 2)) + 1)) * 10;
        var kv: [@sizeOf(u32)]u8 = undefined;
        std.mem.writeInt(u32, kv[0..], next, .big);
        var it = try sl.find(&kv);
        defer it.deinit();

        const cmp_res = keyCmp(&model, (try it.key()), &kv);

        try std.testing.expectEqual(cmp_res, .eq);
        it = try sl.removeItr(it);
        expected_key += 20;
        count += 1;
        if (!it.isEnd()) {
            const tk = try it.key();
            std.mem.writeInt(u32, kv[0..], expected_key, .big);
            // std.debug.print("Next key after removal: {any}\n", .{tk});
            // std.debug.print("Expected key: {any}\n", .{kv});
            const cmp_res0 = keyCmp(&model, tk, &kv);
            try std.testing.expectEqual(cmp_res0, .eq);
        }
    }

    _ = try sl.dump(keyDumper, valueDumper);

    timestampPrint("Done removing the keys...\n", .{});
    //    try std.testing.expectEqual(count, half);
}

fn keyCmpU32(_: anytype, k1: u32, k2: u32) std.math.Order {
    return std.math.order(k1, k2);
}

/// Collect the level-0 key sequence of a memory-backed list as u32s.
fn collectMemLevel0(comptime SL: type, sl: *SL, allocator: std.mem.Allocator) !std.ArrayList(u32) {
    const acc = sl.getModel().getAccessor();
    var list = try std.ArrayList(u32).initCapacity(allocator, 0);
    errdefer list.deinit(allocator);
    var curr = try acc.getRoot(0);
    while (curr) |pid| {
        var node = try acc.loadNode(pid);
        defer acc.deinitNode(&node);
        try list.append(allocator, (try node.getKey()).*);
        if (list.items.len > 100_000) return error.CollectOverflow; // cycle guard
        curr = try node.getNext(0);
    }
    return list;
}

/// Collect the level-0 key sequence of a paged-backed list as u32s (keys are 4-byte big-endian).
fn collectPagedLevel0(comptime SL: type, sl: *SL, allocator: std.mem.Allocator) !std.ArrayList(u32) {
    const acc = sl.getModel().getAccessor();
    var list = try std.ArrayList(u32).initCapacity(allocator, 0);
    errdefer list.deinit(allocator);
    var curr = try acc.getRoot(0);
    while (curr) |pid| {
        var node = try acc.loadNode(pid);
        defer acc.deinitNode(&node);
        const ko = try node.getKey();
        try list.append(allocator, std.mem.readInt(u32, ko[0..4], .big));
        if (list.items.len > 100_000) return error.CollectOverflow; // cycle guard
        curr = try node.getNext(0);
    }
    return list;
}

/// memory == paged == sorted(oracle) for the level-0 (fully ordered) sequence.
fn expectParity(
    comptime MemSL: type,
    mem_sl: *MemSL,
    comptime PagedSL: type,
    paged_sl: *PagedSL,
    oracle: *std.AutoHashMap(u32, void),
    allocator: std.mem.Allocator,
) !void {
    var mem_keys = try collectMemLevel0(MemSL, mem_sl, allocator);
    defer mem_keys.deinit(allocator);
    var paged_keys = try collectPagedLevel0(PagedSL, paged_sl, allocator);
    defer paged_keys.deinit(allocator);

    // the two independent implementations agree
    try std.testing.expectEqualSlices(u32, mem_keys.items, paged_keys.items);

    // ...and both match a trivially-correct sorted set
    var sorted = try std.ArrayList(u32).initCapacity(allocator, oracle.count());
    defer sorted.deinit(allocator);
    var it = oracle.keyIterator();
    while (it.next()) |kp| try sorted.append(allocator, kp.*);
    std.mem.sort(u32, sorted.items, {}, std.sort.asc(u32));
    try std.testing.expectEqualSlices(u32, sorted.items, paged_keys.items);
}

test "SkipList paged: randomized parity vs memory model" {
    const allocator = std.testing.allocator;

    const MemModel = MemoryModel(u32, u32, keyCmpU32, void);
    const MemSL = SkipList(MemModel);

    const Device = device.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const PagedModel = ModelType(PageCache, NoneStorageManager, Fsm, keyCmp, void);
    const PagedSL = SkipList(PagedModel);

    // one seed drives the op stream; print it so any failure is reproducible.
    const op_seed = getNowTimestamp();
    std.debug.print("parity op_seed = {d}\n", .{op_seed});
    var op_prng: std.Random.DefaultPrng = .init(op_seed);
    const op_rand = op_prng.random();
    var mem_prng: std.Random.DefaultPrng = .init(op_seed ^ 0xA5A5);
    var paged_prng: std.Random.DefaultPrng = .init(op_seed ^ 0x5A5A);

    var mem_model = try MemModel.init(allocator, 6, mem_prng.random());
    defer mem_model.deinit();
    var mem_sl = MemSL.init(&mem_model);
    defer mem_sl.deinit();

    var dev = try Device.init(allocator, 4096);
    defer dev.deinit();
    var cache = try PageCache.init(&dev, allocator, 32);
    defer cache.deinit();
    var mgr = NoneStorageManager{};
    var fsm_mem = try FsmMem.init(allocator);
    defer fsm_mem.deinit();
    var fsm_inst = Fsm.init(&fsm_mem);
    defer fsm_inst.deinit();

    var paged_model = PagedModel.init(&cache, &mgr, &fsm_inst, .{
        .max_level = 6,
        .key_len = 4,
        .value_len = 4,
    }, {}, paged_prng.random(), allocator);
    defer paged_model.deinit();
    var paged_sl = PagedSL.init(&paged_model);
    defer paged_sl.deinit();

    // the set of keys currently present (independent oracle)
    var oracle = std.AutoHashMap(u32, void).init(allocator);
    defer oracle.deinit();

    const N_OPS = 2000;
    const KEY_RANGE = 256;

    for (0..N_OPS) |i| {
        const k = op_rand.intRangeLessThan(u32, 0, KEY_RANGE);
        var kv: [4]u8 = undefined;
        std.mem.writeInt(u32, kv[0..], k, .big);

        // toggle: present -> remove from both, absent -> insert into both.
        // keeps the op stream well-defined (no dup-insert / remove-absent semantics).
        if (oracle.contains(k)) {
            try mem_sl.remove(k);
            try paged_sl.remove(&kv);
            _ = oracle.remove(k);
        } else {
            try mem_sl.insert(k, k);
            try paged_sl.insert(&kv, &kv);
            try oracle.put(k, {});
        }

        if (i % 500 == 0) {
            try expectParity(MemSL, &mem_sl, PagedSL, &paged_sl, &oracle, allocator);
        }
    }

    try expectParity(MemSL, &mem_sl, PagedSL, &paged_sl, &oracle, allocator);

    // find parity across the whole key space: present AND absent keys agree on both models.
    for (0..KEY_RANGE) |kk| {
        const k: u32 = @intCast(kk);
        var kv: [4]u8 = undefined;
        std.mem.writeInt(u32, kv[0..], k, .big);
        const want = oracle.contains(k);

        var mit = try mem_sl.find(k);
        defer mit.deinit();
        var pit = try paged_sl.find(&kv);
        defer pit.deinit();

        try std.testing.expectEqual(want, !mit.isEnd());
        try std.testing.expectEqual(want, !pit.isEnd());
        if (want) {
            try std.testing.expectEqual(k, (try mit.key()).*);
            try std.testing.expectEqual(k, std.mem.readInt(u32, (try pit.key())[0..4], .big));
        }
    }
}
