const std = @import("std");
const fullaz = @import("fullaz");
const fsm = fullaz.storage.fsm;
const PageCacheT = fullaz.storage.page_cache.PageCache;
const dev = fullaz.device;

const SizePolicy = struct {
    const Self = @This();
    pub const SizeClass = u16;
    pub fn getSizeClass(_: *const Self, size: SizeClass) !SizeClass {
        return size >> 8;
    }
    pub fn count(_: *const Self) usize {
        return 256; // u16 >> 8 -> classes 0..255
    }
};

const HashContext = struct {
    const Self = @This();
    pub const Hash = u16;
    pub fn hash(_: *const Self, value: u16) Hash {
        return value;
    }
    pub fn eql(_: *const Self, a: Hash, b: Hash) bool {
        return a == b;
    }
};

/// Test double for the slab-root manager. It records 'destroyPage' calls so tests can
/// assert the MODEL destroys an emptied slab page (a real interaction, not mock behavior).
const NoneStorageManager = struct {
    const Self = @This();
    pub const PageId = u32;
    pub const SizeClass = u16;
    pub const Error = std.mem.Allocator.Error;
    const RootStorage = std.HashMap(SizeClass, PageId, HashContext, 50);

    allocator: std.mem.Allocator = undefined,
    root_storage: RootStorage = undefined,
    destroyed: std.ArrayList(PageId) = undefined,

    fn init(allocator: std.mem.Allocator) !Self {
        return .{
            .allocator = allocator,
            .root_storage = RootStorage.init(allocator),
            .destroyed = try std.ArrayList(PageId).initCapacity(allocator, 4),
        };
    }

    fn deinit(self: *Self) void {
        self.root_storage.deinit();
        self.destroyed.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn destroyPage(self: *Self, id: PageId) Error!void {
        try self.destroyed.append(self.allocator, id);
    }

    fn wasDestroyed(self: *const Self, id: PageId) bool {
        for (self.destroyed.items) |d| {
            if (d == id) return true;
        }
        return false;
    }

    pub fn setSizeClassRoot(self: *Self, class: SizeClass, pid: ?PageId) Error!void {
        _ = self.root_storage.remove(class);
        if (pid) |p| {
            try self.root_storage.put(class, p);
        }
    }

    pub fn getSizeClassRoot(self: *Self, class: SizeClass) Error!?PageId {
        return self.root_storage.get(class);
    }
};

const Device = dev.MemoryBlock(u32);
const PageCache = PageCacheT(Device);
const Model = fsm.models.paged.slab.Model(PageCache, NoneStorageManager, SizePolicy);
const Map = fsm.Fsm2(Model);

fn makeDataPage(cache: *PageCache) !u32 {
    var ph = try cache.create();
    defer ph.deinit();
    return try ph.pid();
}

fn inSet(pids: []const u32, pid: u32) bool {
    for (pids) |p| {
        if (p == pid) return true;
    }
    return false;
}

/// Add same-class entries (all with free space 'free') until the class's slab page fills
/// and a second chain page is prepended as the new root, then add 'extra' more onto it.
/// 'pids[0..s-1]' live on the tail page ('page1'); 'pids[s..total-1]' on the head/root ('page2').
const Spill = struct {
    page1: u32,
    page2: u32,
    s: usize,
    total: usize,
    pids: [512]u32,
};

fn fillUntilSpill(map: *Map, sm: *NoneStorageManager, cache: *PageCache, free: u16, extra: usize) !Spill {
    const policy = SizePolicy{};
    const class = try policy.getSizeClass(free);
    var pids: [512]u32 = undefined;
    var first_root: ?u32 = null;
    var s: usize = 0;
    var spilled = false;
    var i: usize = 0;
    while (i < pids.len) : (i += 1) {
        pids[i] = try makeDataPage(cache);
        try map.add(pids[i], free);
        const root = (try sm.getSizeClassRoot(class)).?;
        if (first_root == null) first_root = root;
        if (root != first_root.?) {
            s = i; // pids[i] is the first entry on the new page
            spilled = true;
            break;
        }
    }
    if (!spilled) {
        return error.NoSpill;
    }
    const page1 = first_root.?;
    const page2 = (try sm.getSizeClassRoot(class)).?;
    var k: usize = 0;
    while (k < extra) : (k += 1) {
        pids[s + 1 + k] = try makeDataPage(cache);
        try map.add(pids[s + 1 + k], free);
    }
    return .{ .page1 = page1, .page2 = page2, .s = s, .total = s + 1 + extra, .pids = pids };
}

test "Fsm2 paged: add, find, update, remove" {
    const allocator = std.testing.allocator;
    var sm = try NoneStorageManager.init(allocator);
    defer sm.deinit();
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 16);
    defer cache.deinit();

    var model = Model.init(&cache, &sm, SizePolicy{}, .{});
    var map = Map.init(&model);
    defer map.deinit();

    const d1 = try makeDataPage(&cache); // class 1000>>8 = 3
    const d2 = try makeDataPage(&cache); // class 2000>>8 = 7
    const d3 = try makeDataPage(&cache); // class 1500>>8 = 5

    try map.add(d1, 1000);
    try map.add(d2, 2000);
    try map.add(d3, 1500);

    try std.testing.expectEqual(@as(?u32, d3), try map.find(1200));
    try std.testing.expectEqual(@as(?u32, d2), try map.find(1800));
    try std.testing.expectEqual(@as(?u32, d2), try map.find(1501));
    try std.testing.expectEqual(@as(?u32, null), try map.find(5000));

    try map.update(d1, 5000);
    try std.testing.expectEqual(@as(?u32, d1), try map.find(4000));

    try map.remove(d2);
    try std.testing.expectEqual(@as(?u32, d1), try map.find(1800));
}

test "Fsm2 paged: a full slab page spills into a second chain page" {
    const allocator = std.testing.allocator;
    var sm = try NoneStorageManager.init(allocator);
    defer sm.deinit();
    var device = try Device.init(allocator, 256); // small page => small slab capacity
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 128);
    defer cache.deinit();

    var model = Model.init(&cache, &sm, SizePolicy{}, .{});
    var map = Map.init(&model);
    defer map.deinit();

    const sp = try fillUntilSpill(&map, &sm, &cache, 100, 2); // class 0
    // a real second page was created and prepended as the new class root
    try std.testing.expect(sp.page1 != sp.page2);
    try std.testing.expectEqual(@as(?u32, sp.page2), try sm.getSizeClassRoot(0));
    // entries remain findable; nothing oversized fits
    try std.testing.expect((try map.find(100)) != null);
    try std.testing.expectEqual(@as(?u32, null), try map.find(60000));
}

test "Fsm2 paged: emptying a slab page destroys it and clears the class root" {
    const allocator = std.testing.allocator;
    var sm = try NoneStorageManager.init(allocator);
    defer sm.deinit();
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 16);
    defer cache.deinit();

    var model = Model.init(&cache, &sm, SizePolicy{}, .{});
    var map = Map.init(&model);
    defer map.deinit();

    const a = try makeDataPage(&cache);
    const b = try makeDataPage(&cache);
    const c = try makeDataPage(&cache);
    try map.add(a, 100); // all class 0, one slab page
    try map.add(b, 110);
    try map.add(c, 120);

    const slab = (try sm.getSizeClassRoot(0)).?;

    try map.remove(a);
    try map.remove(b);
    // still has one entry: page alive, root unchanged
    try std.testing.expect(!sm.wasDestroyed(slab));
    try std.testing.expectEqual(@as(?u32, slab), try sm.getSizeClassRoot(0));

    try map.remove(c); // now empty
    try std.testing.expect(sm.wasDestroyed(slab));
    try std.testing.expectEqual(@as(?u32, null), try sm.getSizeClassRoot(0));
    try std.testing.expectEqual(@as(?u32, null), try map.find(100));
}

test "Fsm2 paged: removing the tail page unlinks it, root unchanged" {
    const allocator = std.testing.allocator;
    var sm = try NoneStorageManager.init(allocator);
    defer sm.deinit();
    var device = try Device.init(allocator, 256);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 128);
    defer cache.deinit();

    var model = Model.init(&cache, &sm, SizePolicy{}, .{});
    var map = Map.init(&model);
    defer map.deinit();

    const sp = try fillUntilSpill(&map, &sm, &cache, 100, 2);

    // empty page1 (the tail): remove every entry that lives on it
    var i: usize = 0;
    while (i < sp.s) : (i += 1) {
        try map.remove(sp.pids[i]);
    }

    try std.testing.expect(sm.wasDestroyed(sp.page1));
    try std.testing.expect(!sm.wasDestroyed(sp.page2));
    // head page stays the root; its entries still findable
    try std.testing.expectEqual(@as(?u32, sp.page2), try sm.getSizeClassRoot(0));
    try std.testing.expect((try map.find(100)) != null);
}

test "Fsm2 paged: removing the head page advances the class root to next" {
    const allocator = std.testing.allocator;
    var sm = try NoneStorageManager.init(allocator);
    defer sm.deinit();
    var device = try Device.init(allocator, 256);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 128);
    defer cache.deinit();

    var model = Model.init(&cache, &sm, SizePolicy{}, .{});
    var map = Map.init(&model);
    defer map.deinit();

    const sp = try fillUntilSpill(&map, &sm, &cache, 100, 2);

    // empty page2 (the head/root): remove every entry that lives on it
    var i: usize = sp.s;
    while (i < sp.total) : (i += 1) {
        try map.remove(sp.pids[i]);
    }

    try std.testing.expect(sm.wasDestroyed(sp.page2));
    try std.testing.expect(!sm.wasDestroyed(sp.page1));
    // root advances to the surviving tail page; its entries still findable
    try std.testing.expectEqual(@as(?u32, sp.page1), try sm.getSizeClassRoot(0));
    try std.testing.expect((try map.find(100)) != null);
}

test "Fsm2 paged: find walks the chain to a non-root page" {
    const allocator = std.testing.allocator;
    var sm = try NoneStorageManager.init(allocator);
    defer sm.deinit();
    var device = try Device.init(allocator, 256);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 128);
    defer cache.deinit();

    var model = Model.init(&cache, &sm, SizePolicy{}, .{});
    var map = Map.init(&model);
    defer map.deinit();

    // page1 fills with free=300 (class 1); page2 (root) gets only the overflow entry
    const sp = try fillUntilSpill(&map, &sm, &cache, 300, 0);

    // add smaller, same-class (257>>8 == 1) entries onto the root page
    var small: [3]u32 = undefined;
    for (&small) |*x| {
        x.* = try makeDataPage(&cache);
        try map.add(x.*, 257);
    }
    // drop the lone free=300 entry on the root page so it no longer satisfies find(280)
    try map.remove(sp.pids[sp.s]);

    // root page now holds only free=257 (< 280): find must WALK to page1 (free=300)
    const got = try map.find(280);
    try std.testing.expect(got != null);
    try std.testing.expect(inSet(sp.pids[0..sp.s], got.?));
}
