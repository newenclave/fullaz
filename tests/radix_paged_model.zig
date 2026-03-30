const std = @import("std");
const radix_tree = @import("fullaz").radix_tree;
const PageCacheT = @import("fullaz").storage.page_cache.PageCache;
const dev = @import("fullaz").device;

const RadixModel = radix_tree.models.paged.Model;
const View = radix_tree.models.paged.View;

test "RadixTree paged: leaf create/format" {
    const PageView = View(u32, u16, u64, 16, std.builtin.Endian.little, false);
    const LeafSubheader = PageView.LeafSubheaderView;

    var tmp_buf = [_]u8{0} ** 4096;
    var leaf_view = LeafSubheader.init(&tmp_buf);
    try leaf_view.formatPage(0x5678, 0x9abc, 0);
    try leaf_view.check();

    try std.testing.expect(try leaf_view.slotSize() == 16);

    std.debug.print("slot size: {}\n", .{try leaf_view.slotSize()});
    std.debug.print("slot capacity: {}\n", .{try leaf_view.slotsCapacity()});
}

test "RadixTree paged: inode create/format" {
    const PageView = View(u32, u16, u64, 16, std.builtin.Endian.little, false);
    const InodeSubheader = PageView.InodeSubheaderView;

    var tmp_buf = [_]u8{0} ** 4096;
    var inode_view = InodeSubheader.init(&tmp_buf);
    try inode_view.formatPage(0x5678, 0x9abc, 0);
    try inode_view.check();

    std.debug.print("slot size: {}\n", .{try inode_view.slotSize()});
    std.debug.print("slot capacity: {}\n", .{try inode_view.slotsCapacity()});
}

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

    pub fn hasRoot(self: *const @This()) bool {
        return self.root_block_id != null;
    }

    pub fn destroyPage(_: *@This(), id: PageId) Error!void {
        _ = id;
        // Implement page destruction logic, e.g., add to free list
    }
};

test "RadixTree paged: model create" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const Model = RadixModel(PageCache, NoneStorageManager, u64, u64);

    var store_mgr = NoneStorageManager{};
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var page_cache = try PageCache.init(&device, allocator, 16);
    defer page_cache.deinit();
    var model = Model.init(
        &page_cache,
        &store_mgr,
        .{
            .leaf_page_kind = 0x5678,
            .inode_page_kind = 0x9abc,
        },
    );
    defer model.deinit();

    var leaf = try model.accessor.createLeaf();
    defer model.accessor.deinitLeaf(&leaf);
    var leaf_load = try model.accessor.loadLeaf(leaf.id());
    defer model.accessor.deinitLeaf(&leaf_load);

    try std.testing.expect(leaf.id() == 0);
    try std.testing.expect(leaf_load.id() == 0);
}
