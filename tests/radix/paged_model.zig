const std = @import("std");
const radix_tree = @import("fullaz").radix_tree;
const PageCacheT = @import("fullaz").storage.page_cache.PageCache;
const dev = @import("fullaz").device;
const printer = @import("test_printer");

const RadixModel = radix_tree.models.paged.Model;
const View = radix_tree.models.paged.View;
const TreeType = radix_tree.Tree;

test "RadixTree paged: leaf create/format" {
    const PageView = View(u32, u16, u64, 16, std.builtin.Endian.little, false);
    const LeafSubheader = PageView.LeafSubheaderView;

    var tmp_buf = [_]u8{0} ** 4096;
    var leaf_view = LeafSubheader.init(&tmp_buf);
    try leaf_view.formatPage(0x5678, 0x9abc, 0);
    try leaf_view.check();

    try std.testing.expect(try leaf_view.slotSize() == 16);
    try std.testing.expectEqual(@as(?u32, null), try leaf_view.getPrevFreeLeaf());
    try std.testing.expectEqual(@as(?u32, null), try leaf_view.getNextFreeLeaf());

    printer.print("leaf slot size: {}\n", .{try leaf_view.slotSize()});
    printer.print("leaf slot capacity: {}\n", .{try leaf_view.capacity()});
}

test "RadixTree paged: inode create/format" {
    const PageView = View(u32, u16, u64, 16, std.builtin.Endian.little, false);
    const InodeSubheader = PageView.InodeSubheaderView;

    var tmp_buf = [_]u8{0} ** 4096;
    var inode_view = InodeSubheader.init(&tmp_buf);
    try inode_view.formatPage(0x5678, 0x9abc, 0);
    try inode_view.check();

    printer.print("inode slot size: {}\n", .{try inode_view.slotSize()});
    printer.print("inode slot capacity: {}\n", .{try inode_view.capacity()});
}

const NoneStorageManager = struct {
    pub const Self = @This();
    pub const PageId = u32;
    pub const Error = error{};
    root_block_id: ?u32 = null,
    free_leaf_root: ?u32 = null,

    pub fn getRoot(self: *const @This()) ?u32 {
        return self.root_block_id;
    }

    pub fn setRoot(self: *@This(), root: ?u32) Error!void {
        self.root_block_id = root;
        // Persist to disk header, etc.
    }

    pub fn getFreeLeafRoot(self: *const @This()) ?PageId {
        return self.free_leaf_root;
    }

    pub fn setFreeLeafRoot(self: *@This(), root: ?PageId) Error!void {
        self.free_leaf_root = root;
    }

    pub fn destroyPage(_: *@This(), id: PageId) Error!void {
        _ = id;
        // Implement page destruction logic, e.g., add to free list
    }
};

fn TestSuite(comptime BlockIdT: type, comptime StorageManager: type, comptime KeyT: type, comptime ValueT: type) type {
    const Device = dev.MemoryBlock(BlockIdT);
    const PageCache = PageCacheT(Device);
    const Model = RadixModel(PageCache, StorageManager, KeyT, @sizeOf(ValueT));

    return struct {
        const Self = @This();
        const Tree = TreeType(Model);

        allocator: std.mem.Allocator = undefined,
        store_mgr: StorageManager = undefined,
        device: Device = undefined,
        page_cache: PageCache = undefined,
        model: Model = undefined,
        tree: Tree = undefined,
        fn initInPlace(self: *Self) !void {
            self.allocator = std.testing.allocator;
            self.store_mgr = StorageManager{};
            self.device = try Device.init(self.allocator, 4096);
            self.page_cache = try PageCache.init(&self.device, self.allocator, 16);
            self.model = try Model.init(
                &self.page_cache,
                &self.store_mgr,
                .{
                    .leaf_page_kind = 0x5678,
                    .inode_page_kind = 0x9abc,
                    .inode_base = 256,
                    .leaf_base = 256,
                },
            );
            self.tree = Tree.init(&self.model);
        }

        fn deinit(self: *Self) void {
            self.tree.deinit();
            self.model.deinit();
            self.page_cache.deinit();
            self.device.deinit();
        }

        fn reopen(self: *Self) !void {
            self.tree.deinit();
            self.model.deinit();
            self.model = try Model.init(
                &self.page_cache,
                &self.store_mgr,
                .{
                    .leaf_page_kind = 0x5678,
                    .inode_page_kind = 0x9abc,
                    .inode_base = 256,
                    .leaf_base = 256,
                },
            );
            self.tree = Tree.init(&self.model);
        }
    };
}

const FreeLeafState = struct {
    listed: bool,
    prev: ?u32,
    next: ?u32,
};

fn readFreeLeafState(cache: anytype, page_id: u32) !FreeLeafState {
    var page = try cache.fetch(page_id);
    defer page.deinit();
    const view = View(u32, u16, u64, 8, .little, true).LeafSubheaderView.init(try page.data());
    return .{
        .listed = try view.isInFree(),
        .prev = try view.getPrevFreeLeaf(),
        .next = try view.getNextFreeLeaf(),
    };
}

test "RadixTree paged: model create leaf" {
    const TestSuiteType = TestSuite(u32, NoneStorageManager, u64, [32]u8);
    var suite = TestSuiteType{};
    try suite.initInPlace();
    defer suite.deinit();

    var leaf = try suite.model.accessor().createLeaf();
    defer suite.model.accessor().deinitLeaf(&leaf);
    var leaf_load = try suite.model.accessor().loadLeaf(leaf.id());
    defer suite.model.accessor().deinitLeaf(&leaf_load);

    try leaf.set(0xc, "Hello!");
    printer.print("leaf get: {} {s}\n", .{ try leaf.isSet(0xc), try leaf.get(0xc) });
    try leaf.free(0xc);
    printer.print("leaf get: {}\n", .{try leaf.isSet(0xc)});
    try leaf.setParent(0x1234);
    printer.print("leaf parent: {any}\n", .{try leaf.getParent()});
    try leaf.setParentId(0x1234);
    printer.print("leaf parentId: {x}\n", .{try leaf.getParentId()});
    try leaf.setParentQuotient(0x5678);
    printer.print("leaf parentQuotient: {x}\n", .{try leaf.getParentQuotient()});

    printer.print("leaf slots: {} {}\n", .{ try leaf.size(), leaf.calculateSlotCapacity(4096, 0) });

    try std.testing.expect(leaf.id() == 0);
    try std.testing.expect(leaf_load.id() == 0);

    printer.print("LEAF Effective settings: leaf_base={}, inode_base={}\n", .{
        suite.model.effectiveSettings().leaf_base,
        suite.model.effectiveSettings().inode_base,
    });
}

test "RadixTree paged: model create inode" {
    const TestSuiteType = TestSuite(u32, NoneStorageManager, u64, [32]u8);
    var suite = TestSuiteType{};
    try suite.initInPlace();
    defer suite.deinit();

    var inode = try suite.model.accessor().createInode();
    printer.print("inode slots: {} {}\n", .{ try inode.size(), inode.calculateSlotCapacity(4096, 0) });

    defer suite.model.accessor().deinitInode(&inode);
    var inode_load = try suite.model.accessor().loadInode(inode.id());
    defer suite.model.accessor().deinitInode(&inode_load);

    try std.testing.expect(inode.id() == 0);
    try std.testing.expect(inode_load.id() == 0);
}

test "RadixTree paged: model split key" {
    const TestSuiteType = TestSuite(u32, NoneStorageManager, u64, u64);
    var suite = TestSuiteType{};
    try suite.initInPlace();
    defer suite.deinit();

    printer.print("Effective settings: leaf_base={}, inode_base={}\n", .{
        suite.model.effectiveSettings().leaf_base,
        suite.model.effectiveSettings().inode_base,
    });

    const key: u64 = 0x123456789abcdef0;
    var split_key_result = try suite.model.accessor().splitKey(key);
    defer suite.model.accessor().deinitSplitKey(&split_key_result);

    printer.print("Split key result for {x} ({}):\n", .{ key, split_key_result.size() });
    for (0..split_key_result.size()) |i| {
        printer.print("digit {}: {x} {x}\n", .{ i, split_key_result.get(i).digit, split_key_result.get(i).quotient });
    }
}

const StdOut = struct {
    const Self = @This();
    pub fn print(_: *const Self, comptime fmt: []const u8, args: anytype) !void {
        printer.print(fmt, args);
    }
};

test "RadixTree paged: model create tree" {
    const TestSuiteType = TestSuite(u32, NoneStorageManager, u64, [32]u8);
    var suite = TestSuiteType{};
    try suite.initInPlace();
    defer suite.deinit();

    printer.print("Effective settings: leaf_base={}, inode_base={}\n", .{
        suite.model.effectiveSettings().leaf_base,
        suite.model.effectiveSettings().inode_base,
    });

    try suite.tree.set(0x11223344, "Hello!");
    try std.testing.expect(std.mem.startsWith(u8, (try suite.tree.get(0x11223344)).?, "Hello!"));

    try suite.tree.set(0x12, "12345678");
    try suite.tree.set(0x0, "0");
    try suite.tree.set(0x12345678, "87654321");
    try suite.tree.set(0x12345677, "77654321");
    try suite.tree.free(0x0);
    try suite.tree.set(0x3456, "6666");
    try suite.tree.set(0x00, "0");
    try suite.tree.set(0xFFFFFFFF, "FFFFFFFF");
    try suite.tree.set(0x12345679, "99999"); // Adjacent to 0x12345678
    try suite.tree.set(0x12345680, "88888"); // Also nearby
    try suite.tree.set(0x12340000, "77777"); // Same digit[3] and digit[2]

    try std.testing.expect(std.mem.startsWith(u8, (try suite.tree.get(0)).?, "0"));
    try std.testing.expect(std.mem.startsWith(u8, (try suite.tree.get(0x3456)).?, "6666"));
    try std.testing.expect(std.mem.startsWith(u8, (try suite.tree.get(0xFFFFFFFF)).?, "FFFFFFFF"));
    try std.testing.expect((try suite.tree.get(0x9999)) == null);

    try suite.tree.dumpTree(StdOut{});
}

test "RadixTree paged: value editor locks layout, rolls back, and finishes" {
    const TestSuiteType = TestSuite(u32, NoneStorageManager, u64, [8]u8);
    var suite = TestSuiteType{};
    try suite.initInPlace();
    defer suite.deinit();

    try suite.tree.set(7, "original");
    var editor = (try suite.tree.openValueEditor(7)).?;
    const value = try editor.valueMut();
    @memcpy(value, "changed!");
    try std.testing.expectError(error.ValueEditorActive, suite.tree.free(7));
    try std.testing.expectError(error.ValueEditorActive, suite.tree.openValueEditor(7));
    editor.deinit();
    try std.testing.expect(std.mem.eql(u8, (try suite.tree.get(7)).?, "original"));

    var finished = (try suite.tree.openValueEditor(7)).?;
    @memcpy(try finished.valueMut(), "finished");
    try finished.finish();
    try std.testing.expectError(error.EditorInvalidated, finished.valueMut());
    try std.testing.expect(std.mem.eql(u8, (try suite.tree.get(7)).?, "finished"));
}

test "RadixTree paged: a leaf root reports level zero" {
    const TestSuiteType = TestSuite(u32, NoneStorageManager, u64, [8]u8);
    var suite = TestSuiteType{};
    try suite.initInPlace();
    defer suite.deinit();

    try suite.tree.set(7, "value");
    try std.testing.expectEqual(@as(?usize, 0), try suite.model.accessor().getRootLevel());
    try std.testing.expect(std.mem.startsWith(u8, (try suite.tree.get(7)).?, "value"));
}

test "RadixTree paged: reuses partial leaves and unlinks empty leaves" {
    const TestSuiteType = TestSuite(u32, NoneStorageManager, u64, [8]u8);
    var suite = TestSuiteType{};
    try suite.initInPlace();
    defer suite.deinit();

    const leaf_base = suite.model.effectiveSettings().leaf_base;
    try suite.tree.set(0, "first");
    const first_leaf_id = suite.store_mgr.free_leaf_root.?;
    try suite.tree.set(leaf_base, "second");
    const second_leaf_id = suite.store_mgr.free_leaf_root.?;
    try std.testing.expect(first_leaf_id != second_leaf_id);

    try suite.tree.free(0);
    try std.testing.expectEqual(@as(?u32, second_leaf_id), suite.store_mgr.free_leaf_root);
    try std.testing.expect(std.mem.startsWith(u8, (try suite.tree.get(leaf_base)).?, "second"));

    try std.testing.expectEqual(
        @as(?u64, @as(u64, leaf_base) + 1),
        try suite.tree.takeFree("reused"),
    );
    try std.testing.expect(std.mem.startsWith(u8, (try suite.tree.get(leaf_base + 1)).?, "reused"));
}

test "RadixTree paged: free leaf list unlinks in constant time" {
    const TestSuiteType = TestSuite(u32, NoneStorageManager, u64, [8]u8);
    var suite = TestSuiteType{};
    try suite.initInPlace();
    defer suite.deinit();

    const leaf_base = suite.model.effectiveSettings().leaf_base;
    try suite.tree.set(0, "first");
    const tail_id = suite.store_mgr.free_leaf_root.?;
    try suite.tree.set(leaf_base, "second");
    const middle_id = suite.store_mgr.free_leaf_root.?;
    try suite.tree.set(@as(u64, leaf_base) * 2, "third");
    const head_id = suite.store_mgr.free_leaf_root.?;

    try suite.reopen();

    const head = try readFreeLeafState(&suite.page_cache, head_id);
    try std.testing.expectEqual(@as(?u32, null), head.prev);
    try std.testing.expectEqual(@as(?u32, middle_id), head.next);
    const middle = try readFreeLeafState(&suite.page_cache, middle_id);
    try std.testing.expectEqual(@as(?u32, head_id), middle.prev);
    try std.testing.expectEqual(@as(?u32, tail_id), middle.next);
    const tail = try readFreeLeafState(&suite.page_cache, tail_id);
    try std.testing.expectEqual(@as(?u32, middle_id), tail.prev);
    try std.testing.expectEqual(@as(?u32, null), tail.next);

    try suite.model.accessor().removeFreeLeaf(middle_id);
    try std.testing.expectEqual(@as(?u32, head_id), suite.store_mgr.free_leaf_root);
    try std.testing.expectEqual(@as(?u32, tail_id), (try readFreeLeafState(&suite.page_cache, head_id)).next);
    const removed_middle = try readFreeLeafState(&suite.page_cache, middle_id);
    try std.testing.expect(!removed_middle.listed);
    try std.testing.expectEqual(@as(?u32, null), removed_middle.prev);
    try std.testing.expectEqual(@as(?u32, null), removed_middle.next);
    try std.testing.expectEqual(@as(?u32, head_id), (try readFreeLeafState(&suite.page_cache, tail_id)).prev);

    try suite.model.accessor().removeFreeLeaf(head_id);
    try std.testing.expectEqual(@as(?u32, tail_id), suite.store_mgr.free_leaf_root);
    try suite.model.accessor().removeFreeLeaf(tail_id);
    try std.testing.expectEqual(@as(?u32, null), suite.store_mgr.free_leaf_root);
}

test "RadixTree paged: full leaves unlink from the free list" {
    const TestSuiteType = TestSuite(u32, NoneStorageManager, u64, [8]u8);
    var suite = TestSuiteType{};
    try suite.initInPlace();
    defer suite.deinit();

    const leaf_base = suite.model.effectiveSettings().leaf_base;
    try suite.tree.set(0, "first");
    const tail_id = suite.store_mgr.free_leaf_root.?;
    try suite.tree.set(leaf_base, "second");
    const full_id = suite.store_mgr.free_leaf_root.?;
    try suite.tree.set(@as(u64, leaf_base) * 2, "third");
    const head_id = suite.store_mgr.free_leaf_root.?;

    for (1..leaf_base) |offset| {
        try suite.tree.set(@as(u64, leaf_base) + offset, "full");
    }

    try std.testing.expectEqual(@as(?u32, head_id), suite.store_mgr.free_leaf_root);
    try std.testing.expectEqual(@as(?u32, tail_id), (try readFreeLeafState(&suite.page_cache, head_id)).next);
    const full = try readFreeLeafState(&suite.page_cache, full_id);
    try std.testing.expect(!full.listed);
    try std.testing.expectEqual(@as(?u32, null), full.prev);
    try std.testing.expectEqual(@as(?u32, null), full.next);
    try std.testing.expectEqual(@as(?u32, head_id), (try readFreeLeafState(&suite.page_cache, tail_id)).prev);
}

test "RadixTree paged: free leaf list rejects malformed links" {
    const TestSuiteType = TestSuite(u32, NoneStorageManager, u64, [8]u8);
    var suite = TestSuiteType{};
    try suite.initInPlace();
    defer suite.deinit();

    const accessor = suite.model.accessor();
    var leaf = try accessor.createLeaf();
    const leaf_id = leaf.id();
    try leaf.set(0, "value");
    accessor.deinitLeaf(&leaf);

    var page = try suite.page_cache.fetch(leaf_id);
    defer page.deinit();
    var view = View(u32, u16, u64, 8, .little, false).LeafSubheaderView.init(try page.dataMut());
    try view.setFreeLeafLinks(null, leaf_id);
    try suite.store_mgr.setFreeLeafRoot(leaf_id);

    try std.testing.expectError(error.BadData, accessor.getFreeLeaf());
}

test "RadixTree paged scanners visit occupied slots only" {
    const TestSuiteType = TestSuite(u32, NoneStorageManager, u64, [8]u8);
    const Visitor = struct {
        expected_child: u32,
        refs: usize = 0,
        values: usize = 0,

        pub fn hasValueScanner(_: *const @This()) bool {
            return true;
        }

        pub fn visit(self: *@This(), page_id: u32) !void {
            try std.testing.expectEqual(self.expected_child, page_id);
            self.refs += 1;
        }

        pub fn visitValue(self: *@This(), _: []const u8) !void {
            self.values += 1;
        }
    };

    var suite = TestSuiteType{};
    try suite.initInPlace();
    defer suite.deinit();

    var leaf = try suite.model.accessor().createLeaf();
    const leaf_id = leaf.id();
    try leaf.set(1, "value");
    try leaf.set(2, "unused");
    try leaf.free(2);
    suite.model.accessor().deinitLeaf(&leaf);

    var free_leaf = try suite.model.accessor().createLeaf();
    const free_leaf_id = free_leaf.id();
    try free_leaf.set(1, "linked");
    try suite.model.accessor().addFreeLeaf(&free_leaf);
    suite.model.accessor().deinitLeaf(&free_leaf);

    var listed_leaf = try suite.model.accessor().loadLeaf(leaf_id);
    try suite.model.accessor().addFreeLeaf(&listed_leaf);
    suite.model.accessor().deinitLeaf(&listed_leaf);

    var inode = try suite.model.accessor().createInode();
    const inode_id = inode.id();
    try inode.set(1, leaf_id);
    try inode.set(2, leaf_id);
    try inode.free(2);
    suite.model.accessor().deinitInode(&inode);

    var visitor = Visitor{ .expected_child = leaf_id };
    var inode_page = try suite.page_cache.fetch(inode_id);
    defer inode_page.deinit();
    try suite.tree.scanInodeRefs(inode_id, try inode_page.data(), &visitor);
    try std.testing.expectEqual(@as(usize, 1), visitor.refs);

    var leaf_page = try suite.page_cache.fetch(leaf_id);
    defer leaf_page.deinit();
    try suite.tree.scanLeafRefs(leaf_id, try leaf_page.data(), &visitor);
    try std.testing.expectEqual(@as(usize, 1), visitor.values);
    try std.testing.expectEqual(@as(usize, 1), visitor.refs);
    try std.testing.expectEqual(@as(?u32, leaf_id), suite.store_mgr.free_leaf_root);
    try std.testing.expectEqual(@as(u32, free_leaf_id), blk: {
        const listed_view = View(u32, u16, u64, 8, .little, true).LeafSubheaderView.init(try leaf_page.data());
        break :blk (try listed_view.getNextFreeLeaf()).?;
    });
}
