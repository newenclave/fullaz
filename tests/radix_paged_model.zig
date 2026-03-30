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

fn TestSuite(comptime BlockIdT: type, comptime StorageManager: type, comptime KeyT: type, comptime ValueT: type) type {
    const Device = dev.MemoryBlock(BlockIdT);
    const PageCache = PageCacheT(Device);
    const Model = RadixModel(PageCache, StorageManager, KeyT, ValueT);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator = undefined,
        store_mgr: StorageManager = undefined,
        device: Device = undefined,
        page_cache: PageCache = undefined,
        model: Model = undefined,
        fn initInPlace(self: *Self) !void {
            self.allocator = std.testing.allocator;
            self.store_mgr = StorageManager{};
            self.device = try Device.init(self.allocator, 4096);
            self.page_cache = try PageCache.init(&self.device, self.allocator, 16);
            self.model = Model.init(
                &self.page_cache,
                &self.store_mgr,
                .{
                    .leaf_page_kind = 0x5678,
                    .inode_page_kind = 0x9abc,
                    .inode_base = 256,
                    .leaf_base = 256,
                },
            );
        }

        fn deinit(self: *Self) void {
            self.model.deinit();
            self.page_cache.deinit();
            self.device.deinit();
        }
    };
}

test "RadixTree paged: model create" {
    const TestSuiteType = TestSuite(u32, NoneStorageManager, u64, u64);
    var suite = TestSuiteType{};
    try suite.initInPlace();
    defer suite.deinit();

    var leaf = try suite.model.accessor.createLeaf();
    std.debug.print("leaf slots: {} {}\n", .{ try leaf.size(), leaf.calculateSlotCapacity(4096, 0) });

    defer suite.model.accessor.deinitLeaf(&leaf);
    var leaf_load = try suite.model.accessor.loadLeaf(leaf.id());
    defer suite.model.accessor.deinitLeaf(&leaf_load);

    try std.testing.expect(leaf.id() == 0);
    try std.testing.expect(leaf_load.id() == 0);

    var inode = try suite.model.accessor.createInode();
    std.debug.print("inode slots: {} {}\n", .{ try inode.size(), inode.calculateSlotCapacity(4096, 0) });

    defer suite.model.accessor.deinitInode(&inode);
    var inode_load = try suite.model.accessor.loadInode(inode.id());
    defer suite.model.accessor.deinitInode(&inode_load);

    try std.testing.expect(inode.id() == 1);
    try std.testing.expect(inode_load.id() == 1);
}

test "RadixTree paged: model split key" {
    const TestSuiteType = TestSuite(u32, NoneStorageManager, u64, u64);
    var suite = TestSuiteType{};
    try suite.initInPlace();
    defer suite.deinit();

    std.debug.print("Effective settings: leaf_base={}, inode_base={}\n", .{
        suite.model.effectiveSettings().leaf_base,
        suite.model.effectiveSettings().inode_base,
    });

    const key: u64 = 0x123456789abcdef0;
    var split_key_result = try suite.model.accessor.splitKey(key);
    defer suite.model.accessor.deinitSplitKey(&split_key_result);

    std.debug.print("Split key result for {x} ({}):\n", .{ key, split_key_result.size() });
    for (0..split_key_result.size()) |i| {
        std.debug.print("digit {}: {x} {x}\n", .{ i, split_key_result.get(i).digit, split_key_result.get(i).quotient });
    }
}
