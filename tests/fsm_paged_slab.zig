const std = @import("std");
const fullaz = @import("fullaz");
const fsm = fullaz.storage.fsm;
const PageCacheT = @import("fullaz").storage.page_cache.PageCache;
const dev = @import("fullaz").device;

const paged_slab = fsm.models.paged_slab;
const SlabModel = paged_slab.Model;

const SlabStorageManagerImpl = struct {
    const Bucket = std.ArrayList(u32);
    buckets: std.ArrayList(Bucket),
};

const SizePolicy = struct {
    pub const Self = @This();
    pub const SizeClass = u16;
    pub fn getSizeClass(_: *const Self, size: SizeClass) !SizeClass {
        return size >> 8;
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
    pub const Self = @This();
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

    pub fn destroyPage(_: *@This(), id: PageId) Error!void {
        _ = id;
        // Implement page destruction logic, e.g., add to free list
    }

    pub fn setSizeClassRoot(self: *Self, class: SizeClass, pid: ?PageId) Error!void {
        _ = self.root_storage.remove(class);
        if (pid) |p| {
            try self.root_storage.put(class, p);
        } else {
            // to do...
        }
    }

    pub fn getSizeClassRoot(self: *Self, class: SizeClass) Error!?PageId {
        if (self.root_storage.get(class)) |pid| {
            return pid;
        } else {
            return null;
        }
        return null; // Not implemented, as this is a placeholder
    }
};

test "SlotAllocator paged_slab: create the view" {
    const View = paged_slab.View(u32, u16, u16, std.builtin.Endian.little, false).SlabPageView;
    var data = [_]u8{0} ** 1024;
    var view = View.init(&data);
    try view.formatPage(1, 42, 0, 3);

    try std.testing.expectEqual(1, view.page_view.header().kind.get());
    try std.testing.expectEqual(42, view.page_view.header().self_pid.get());
    try std.testing.expectEqual(@sizeOf(View.SubheaderType), view.page_view.header().subheader_size.get());
    try std.testing.expectEqual(0, view.page_view.header().metadata_size.get());

    try std.testing.expectEqual(null, view.getNext());
    try std.testing.expectEqual(null, view.getPrev());

    try view.setNext(1000);
    try view.setPrev(2000);
    try std.testing.expectEqual(1000, view.getNext());
    try std.testing.expectEqual(2000, view.getPrev());
    try std.testing.expectEqual(3, view.sizeClass());

    const s0 = try view.insert(123, 456);
    const s1 = try view.insert(124, 789);
    const s2 = try view.insert(125, 1024);

    _ = s2;

    const p1 = try view.findByPid(123);
    try std.testing.expectEqual(p1.?.free_space, s0.free_space);
    try std.testing.expectEqual(p1.?.slot_id, s0.slot_id);

    const ps2 = try view.findBySize(700);
    try std.testing.expectEqual(ps2.?.free_space, s1.free_space);
    try std.testing.expectEqual(ps2.?.slot_id, s1.slot_id);
}

test "SlotAllocator paged_slab: create the model" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const Model = SlabModel(PageCache, NoneStorageManager, SizePolicy);

    var store_mgr = try NoneStorageManager.init(allocator);
    defer store_mgr.deinit(allocator);

    const policy = SizePolicy{};

    try store_mgr.setSizeClassRoot(1, 100);
    const c = try store_mgr.getSizeClassRoot(1);
    try std.testing.expectEqual(c.?, 100);
    std.debug.print("SizeClass 1 root: {d}\n", .{c.?});

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();

    var model = try Model.init(&cache, &store_mgr, policy, .{});

    var page = try model.createPage(2);
    defer page.deinit();

    var page2 = try model.createPage(2);
    defer page2.deinit();

    try page2.insertBefore(&page);

    var next = try page2.fetchNext();
    defer {
        if (next) |*n| {
            n.deinit();
        }
    }

    try std.testing.expectEqual(try page.id(), (next.?.id()));

    var common = try page.fetchCommonPage(try page2.id());
    defer common.deinit();

    try std.testing.expectEqual(try page2.id(), (try common.header()).self_pid.get());
}

test "SlotAllocator paged_slab: add to model" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const Model = SlabModel(PageCache, NoneStorageManager, SizePolicy);

    var store_mgr = try NoneStorageManager.init(allocator);
    defer store_mgr.deinit(allocator);

    const policy = SizePolicy{};

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();

    var model = try Model.init(&cache, &store_mgr, policy, .{});
    const a = try model.add(1, 100);
    const b = try model.add(2, 200);
    const c = try model.add(3, 300);

    std.debug.print("Added slots: {d}, {d}, {d}\n", .{
        try policy.getSizeClass(100),
        try policy.getSizeClass(200),
        try policy.getSizeClass(300),
    });

    std.debug.print("{}, {}, {}", .{ a.pid, b.pid, c.pid });
}
