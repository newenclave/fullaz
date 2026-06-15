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

const NoneStorageManager = struct {
    pub const Self = @This();
    pub const PageId = u32;
    pub const Error = error{};
    root_block_id: ?u32 = null,

    pub fn getRoot(self: *const @This()) ?u32 {
        return self.root_block_id;
    }

    pub fn setRoot(self: *@This(), root: ?u32) Error!void {
        self.root_block_id = root;
        // Persist to disk header, etc.
    }

    pub fn destroyPage(_: *@This(), id: PageId) Error!void {
        _ = id;
        // Implement page destruction logic, e.g., add to free list
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
    try std.testing.expectEqual(p1, s0);

    const ps2 = try view.findBySize(700);
    try std.testing.expectEqual(ps2, s1);
}

test "SlotAllocator paged_slab: create the model" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const Model = SlabModel(PageCache, NoneStorageManager, u16);

    var store_mgr = NoneStorageManager{};
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();

    var model = try Model.init(&cache, &store_mgr, .{});

    var page = try model.createPage(2);
    defer page.deinit();
}
