const std = @import("std");
const fullaz = @import("fullaz");
const fsm2 = fullaz.storage.fsm2;
const PageCacheT = fullaz.storage.page_cache.PageCache;
const dev = fullaz.device;

const SizePolicy = struct {
    const Self = @This();
    pub const SizeClass = u16;
    pub fn getSizeClass(_: *const Self, size: SizeClass) !SizeClass {
        return size >> 8;
    }
    pub fn count(_: *const Self) usize {
        return 256;
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

const NoneStorageManager = struct {
    const Self = @This();
    pub const PageId = u32;
    pub const SizeClass = u16;
    pub const Error = std.mem.Allocator.Error;
    const RootStorage = std.HashMap(SizeClass, PageId, HashContext, 50);

    root_storage: RootStorage = undefined,

    fn init(allocator: std.mem.Allocator) !Self {
        var self = Self{};
        self.root_storage = RootStorage.init(allocator);
        return self;
    }

    fn deinit(self: *Self, _: std.mem.Allocator) void {
        self.root_storage.deinit();
        self.* = undefined;
    }

    pub fn destroyPage(_: *Self, id: PageId) Error!void {
        _ = id;
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

fn makeDataPage(cache: anytype) !u32 {
    var ph = try cache.create();
    defer ph.deinit();
    return try ph.pid();
}

test "Fsm2 paged: add, find, update, remove" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const Model = fsm2.models.paged.slab.Model(PageCache, NoneStorageManager, SizePolicy);
    const Map = fsm2.Fsm2(Model);

    var sm = try NoneStorageManager.init(allocator);
    defer sm.deinit(allocator);
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

    try std.testing.expectEqual(@as(?u32, d3), try map.find(1200)); // 1500 fits
    try std.testing.expectEqual(@as(?u32, d2), try map.find(1800)); // 2000 fits
    try std.testing.expectEqual(@as(?u32, d2), try map.find(1501)); // d3=1500 too small -> d2
    try std.testing.expectEqual(@as(?u32, null), try map.find(5000));

    try map.update(d1, 5000);
    try std.testing.expectEqual(@as(?u32, d1), try map.find(4000));

    try map.remove(d2);
    try std.testing.expectEqual(@as(?u32, d1), try map.find(1800)); // d2 gone -> d1=5000
}
