const std = @import("std");
const radix_tree = @import("fullaz").radix_tree;
const PageCacheT = @import("fullaz").storage.page_cache.PageCache;
const dev = @import("fullaz").device;
const printer = @import("test_printer");

const RadixModel = radix_tree.models.paged.Model;
const RadixState = radix_tree.models.paged.State(u32, .little);
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
    pub const StateLeaseType = struct {
        pub const Error = NoneStorageManager.Error;

        manager: *NoneStorageManager,

        pub fn data(self: *const @This()) @This().Error![]const u8 {
            return std.mem.asBytes(@as(*const RadixState, &self.manager.state_value));
        }

        pub fn dataMut(self: *@This()) @This().Error![]u8 {
            return std.mem.asBytes(&self.manager.state_value);
        }

        pub fn finish(self: *@This()) void {
            self.manager.finishes += 1;
        }

        pub fn deinit(self: *@This()) void {
            self.manager.active_leases -= 1;
        }
    };

    state_value: RadixState = .{},
    active_leases: usize = 0,
    finishes: usize = 0,

    pub fn state(self: *Self) Error!StateLeaseType {
        self.active_leases += 1;
        return .{ .manager = self };
    }

    pub fn destroyPage(_: *@This(), id: PageId) Error!void {
        _ = id;
        // Implement page destruction logic, e.g., add to free list
    }
};

fn DestroyTrackingStorageManager(comptime CacheT: type) type {
    return struct {
        const Self = @This();

        pub const PageId = CacheT.Pid;
        pub const Error = error{
            DuplicateDestroy,
            PageStillPinned,
            TooManyPages,
        };

        pub const StateLeaseType = struct {
            pub const Error = Self.Error;

            manager: *Self,

            pub fn data(self: *const @This()) @This().Error![]const u8 {
                return std.mem.asBytes(@as(*const RadixState, &self.manager.state_value));
            }

            pub fn dataMut(self: *@This()) @This().Error![]u8 {
                return std.mem.asBytes(&self.manager.state_value);
            }

            pub fn finish(self: *@This()) void {
                self.manager.finishes += 1;
            }

            pub fn deinit(self: *@This()) void {
                self.manager.active_leases -= 1;
            }
        };

        cache: *CacheT,
        state_value: RadixState = .{},
        active_leases: usize = 0,
        finishes: usize = 0,
        destroyed_pages: usize = 0,
        destroyed: [256]bool = [_]bool{false} ** 256,

        pub fn state(self: *Self) Error!StateLeaseType {
            self.active_leases += 1;
            return .{ .manager = self };
        }

        pub fn destroyPage(self: *Self, page_id: PageId) Error!void {
            if (self.cache.frames_cache.get(page_id)) |frame| {
                if (frame.ref_count != 0) {
                    return error.PageStillPinned;
                }
            }
            const index = std.math.cast(usize, page_id) orelse return error.TooManyPages;
            if (index >= self.destroyed.len) {
                return error.TooManyPages;
            }
            if (self.destroyed[index]) {
                return error.DuplicateDestroy;
            }
            self.destroyed[index] = true;
            self.destroyed_pages += 1;
        }
    };
}

fn freeLeafRoot(manager: anytype) ?u32 {
    const page_id = manager.state_value.free_leaf_root.get();
    return if (page_id == std.math.maxInt(u32)) null else page_id;
}

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

test "RadixTree paged: init rejects slot bases that the key cannot represent" {
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const TinyKeyModel = RadixModel(PageCache, NoneStorageManager, u8, 8);

    var device = try Device.init(std.testing.allocator, 4096);
    defer device.deinit();
    var page_cache = try PageCache.init(&device, std.testing.allocator, 4);
    defer page_cache.deinit();
    var store_mgr = NoneStorageManager{};

    try std.testing.expectError(
        error.InvalidSettings,
        TinyKeyModel.init(
            &page_cache,
            &store_mgr,
            .{
                .leaf_page_kind = 0x5678,
                .inode_page_kind = 0x9abc,
            },
        ),
    );
}

fn expectInvalidKeyGeometry(comptime KeyT: type) !void {
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const InvalidModel = RadixModel(PageCache, NoneStorageManager, KeyT, 8);

    var device = try Device.init(std.testing.allocator, 4096);
    defer device.deinit();
    var page_cache = try PageCache.init(&device, std.testing.allocator, 4);
    defer page_cache.deinit();
    var store_mgr = NoneStorageManager{};

    try std.testing.expectError(
        error.InvalidSettings,
        InvalidModel.init(
            &page_cache,
            &store_mgr,
            .{
                .leaf_page_kind = 0x5678,
                .inode_page_kind = 0x9abc,
            },
        ),
    );
}

test "RadixTree paged: init rejects split workspace larger than a temporary page" {
    try expectInvalidKeyGeometry(u512);
}

test "RadixTree paged: init rejects key depth larger than the durable level" {
    try expectInvalidKeyGeometry(u4096);
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

fn expectTreeValue(tree: anytype, key: anytype, expected: []const u8) !void {
    var entry = (try tree.find(key)) orelse {
        try std.testing.expect(false);
        return;
    };
    defer entry.deinit();
    try std.testing.expect(std.mem.startsWith(u8, (try entry.get()).value, expected));
}

fn expectTreeMissing(tree: anytype, key: anytype) !void {
    var entry = (try tree.find(key)) orelse return;
    defer entry.deinit();
    try std.testing.expect(false);
}

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
    try std.testing.expectEqual(@as(u32, 0), suite.store_mgr.state_value.root.get());
    try std.testing.expect(suite.store_mgr.finishes > 0);
    try std.testing.expectEqual(@as(usize, 0), suite.store_mgr.active_leases);
    try expectTreeValue(&suite.tree, 0x11223344, "Hello!");

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

    try expectTreeValue(&suite.tree, 0, "0");
    try expectTreeValue(&suite.tree, 0x3456, "6666");
    try expectTreeValue(&suite.tree, 0xFFFFFFFF, "FFFFFFFF");
    try expectTreeMissing(&suite.tree, 0x9999);

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
    try expectTreeValue(&suite.tree, 7, "original");

    var finished = (try suite.tree.openValueEditor(7)).?;
    @memcpy(try finished.valueMut(), "finished");
    try finished.finish();
    try std.testing.expectError(error.EditorInvalidated, finished.valueMut());
    try expectTreeValue(&suite.tree, 7, "finished");
}

test "RadixTree paged: point entries block mutations and editors own independent pins" {
    const TestSuiteType = TestSuite(u32, NoneStorageManager, u64, [8]u8);
    var suite = TestSuiteType{};
    try suite.initInPlace();
    defer suite.deinit();

    try suite.tree.set(7, "original");
    const root_id = suite.store_mgr.state_value.root.get();
    const const_tree: *const TestSuiteType.Tree = &suite.tree;
    try std.testing.expect((try const_tree.find(9)) == null);
    try std.testing.expect(!try suite.page_cache.isPinned(root_id));
    try suite.tree.set(8, "existing");

    var entry = (try const_tree.find(7)).?;
    defer entry.deinit();
    try std.testing.expect(try suite.page_cache.isPinned(root_id));
    const found = try entry.get();
    try std.testing.expectEqual(@as(u64, 7), found.key);
    try std.testing.expectEqualSlices(u8, "original", found.value);

    const generation = suite.model.structuralMutationCoordinator().generation();
    try std.testing.expectError(error.ReadHandleActive, suite.tree.free(7));
    try std.testing.expectError(error.ReadHandleActive, suite.tree.set(8, "another!"));
    try std.testing.expectError(error.ReadHandleActive, suite.tree.destroy());
    try std.testing.expectEqual(
        generation,
        suite.model.structuralMutationCoordinator().generation(),
    );
    try std.testing.expectEqualSlices(u8, "original", (try entry.get()).value);
    try expectTreeValue(&suite.tree, 8, "existing");

    var editor = try entry.editValue();
    defer editor.deinit();
    entry.deinit();
    try std.testing.expect(try suite.page_cache.isPinned(root_id));
    try std.testing.expectError(error.InvalidHandle, entry.get());
    try std.testing.expectError(error.InvalidHandle, entry.editValue());
    @memcpy(try editor.valueMut(), "changed!");
    try std.testing.expectError(error.ValueEditorActive, suite.tree.set(8, "another!"));
    try editor.finish();
    try std.testing.expect(!try suite.page_cache.isPinned(root_id));
    try expectTreeValue(&suite.tree, 7, "changed!");

    try suite.tree.free(7);
    try suite.tree.set(7, "restored");
    try suite.tree.destroy();
    try std.testing.expectEqual(@as(?u32, null), try suite.model.accessor().getRoot());
}

test "RadixTree paged: a leaf root reports level zero" {
    const TestSuiteType = TestSuite(u32, NoneStorageManager, u64, [8]u8);
    var suite = TestSuiteType{};
    try suite.initInPlace();
    defer suite.deinit();

    try suite.tree.set(7, "value");
    try std.testing.expectEqual(@as(?usize, 0), try suite.model.accessor().getRootLevel());
    try expectTreeValue(&suite.tree, 7, "value");
}

test "RadixTree paged: reuses partial leaves and unlinks empty leaves" {
    const TestSuiteType = TestSuite(u32, NoneStorageManager, u64, [8]u8);
    var suite = TestSuiteType{};
    try suite.initInPlace();
    defer suite.deinit();

    const leaf_base = suite.model.effectiveSettings().leaf_base;
    try suite.tree.set(0, "first");
    const first_leaf_id = freeLeafRoot(&suite.store_mgr).?;
    try suite.tree.set(leaf_base, "second");
    const second_leaf_id = freeLeafRoot(&suite.store_mgr).?;
    try std.testing.expect(first_leaf_id != second_leaf_id);

    try suite.tree.free(0);
    try std.testing.expectEqual(@as(?u32, second_leaf_id), freeLeafRoot(&suite.store_mgr));
    try expectTreeValue(&suite.tree, leaf_base, "second");

    try std.testing.expectEqual(
        @as(?u64, @as(u64, leaf_base) + 1),
        try suite.tree.takeFree("reused"),
    );
    try expectTreeValue(&suite.tree, leaf_base + 1, "reused");
}

test "RadixTree paged: terminal partial leaf exposes only representable free keys" {
    const TestSuiteType = TestSuite(u32, NoneStorageManager, u16, [8]u8);
    var suite = TestSuiteType{};
    try suite.initInPlace();
    defer suite.deinit();

    const leaf_base: u16 = suite.model.effectiveSettings().leaf_base;
    const max_key = std.math.maxInt(u16);
    const terminal_digit = max_key % leaf_base;
    const terminal_start = max_key - terminal_digit;
    try suite.tree.set(max_key, "maximum!");

    for (0..@as(usize, terminal_digit)) |offset| {
        const expected = terminal_start + @as(u16, @intCast(offset));
        try std.testing.expectEqual(@as(?u16, expected), try suite.tree.takeFree("reused!!"));
        if (offset + 1 == @as(usize, terminal_digit)) {
            try std.testing.expectEqual(@as(?u32, null), freeLeafRoot(&suite.store_mgr));
        }
    }
    try std.testing.expectEqual(@as(?u16, null), try suite.tree.takeFree("blocked!"));
    try std.testing.expectEqual(@as(?u32, null), freeLeafRoot(&suite.store_mgr));
    try expectTreeValue(&suite.tree, max_key, "maximum!");
}

test "RadixTree paged: takeFree unlinks before its final representable write" {
    const TestSuiteType = TestSuite(u32, NoneStorageManager, u64, [8]u8);
    var suite = TestSuiteType{};
    try suite.initInPlace();
    defer suite.deinit();

    const leaf_base = suite.model.effectiveSettings().leaf_base;
    const last_digit = @as(u64, leaf_base) - 1;
    for (0..@as(usize, leaf_base) - 1) |digit| {
        try suite.tree.set(@intCast(digit), "occupied");
    }
    const leaf_id = freeLeafRoot(&suite.store_mgr).?;

    try std.testing.expectError(error.BadLength, suite.tree.takeFree("too-long!"));
    try std.testing.expectEqual(@as(?u32, leaf_id), freeLeafRoot(&suite.store_mgr));
    try expectTreeMissing(&suite.tree, last_digit);

    const invalid_next: u32 = @intCast(suite.device.blocksCount() + 1);
    {
        var page = try suite.page_cache.fetch(leaf_id);
        defer page.deinit();
        var view = View(u32, u16, u64, 8, .little, false).LeafSubheaderView.init(
            try page.dataMut(),
        );
        try view.setFreeLeafLinks(null, invalid_next);
    }
    try std.testing.expectError(error.InvalidId, suite.tree.takeFree("lastfree"));
    try expectTreeMissing(&suite.tree, last_digit);

    {
        var page = try suite.page_cache.fetch(leaf_id);
        defer page.deinit();
        var view = View(u32, u16, u64, 8, .little, false).LeafSubheaderView.init(
            try page.dataMut(),
        );
        try view.setFreeLeafLinks(null, null);
    }
    try std.testing.expectEqual(@as(?u64, last_digit), try suite.tree.takeFree("lastfree"));
    try std.testing.expectEqual(@as(?u32, null), freeLeafRoot(&suite.store_mgr));
    try expectTreeValue(&suite.tree, last_digit, "lastfree");
}

test "RadixTree paged: destroy releases a deep sparse tree without pinned pages" {
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const StorageManager = DestroyTrackingStorageManager(PageCache);
    const Model = RadixModel(PageCache, StorageManager, u64, 8);
    const Tree = TreeType(Model);

    var device = try Device.init(std.testing.allocator, 4096);
    defer device.deinit();
    var page_cache = try PageCache.init(&device, std.testing.allocator, 32);
    defer page_cache.deinit();
    var store_mgr = StorageManager{ .cache = &page_cache };
    var model = try Model.init(
        &page_cache,
        &store_mgr,
        .{
            .leaf_page_kind = 0x5678,
            .inode_page_kind = 0x9abc,
        },
    );
    defer model.deinit();
    var tree = Tree.init(&model);
    defer tree.deinit();

    const leaf_base = @as(u64, model.effectiveSettings().leaf_base);
    try tree.set(0, "zero0000");
    try tree.set(leaf_base, "second!!");
    try tree.set(std.math.maxInt(u64), "maximum!");
    try std.testing.expect((try model.accessor().getRootLevel()).? > 2);
    try std.testing.expect(freeLeafRoot(&store_mgr) != null);
    const page_count = device.blocksCount();

    try tree.destroy();
    try std.testing.expectEqual(@as(?u32, null), try model.accessor().getRoot());
    try std.testing.expectEqual(@as(?u32, null), freeLeafRoot(&store_mgr));
    try std.testing.expectEqual(page_count, store_mgr.destroyed_pages);
    try std.testing.expectEqual(@as(usize, 0), store_mgr.active_leases);
    for (0..page_count) |page_id| {
        try std.testing.expect(store_mgr.destroyed[page_id]);
        try std.testing.expect(!try page_cache.isPinned(@intCast(page_id)));
    }

    try tree.destroy();
    try std.testing.expectEqual(page_count, store_mgr.destroyed_pages);
}

test "RadixTree paged: free leaf list unlinks in constant time" {
    const TestSuiteType = TestSuite(u32, NoneStorageManager, u64, [8]u8);
    var suite = TestSuiteType{};
    try suite.initInPlace();
    defer suite.deinit();

    const leaf_base = suite.model.effectiveSettings().leaf_base;
    try suite.tree.set(0, "first");
    const tail_id = freeLeafRoot(&suite.store_mgr).?;
    try suite.tree.set(leaf_base, "second");
    const middle_id = freeLeafRoot(&suite.store_mgr).?;
    try suite.tree.set(@as(u64, leaf_base) * 2, "third");
    const head_id = freeLeafRoot(&suite.store_mgr).?;

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
    try std.testing.expectEqual(@as(?u32, head_id), freeLeafRoot(&suite.store_mgr));
    try std.testing.expectEqual(@as(?u32, tail_id), (try readFreeLeafState(&suite.page_cache, head_id)).next);
    const removed_middle = try readFreeLeafState(&suite.page_cache, middle_id);
    try std.testing.expect(!removed_middle.listed);
    try std.testing.expectEqual(@as(?u32, null), removed_middle.prev);
    try std.testing.expectEqual(@as(?u32, null), removed_middle.next);
    try std.testing.expectEqual(@as(?u32, head_id), (try readFreeLeafState(&suite.page_cache, tail_id)).prev);

    try suite.model.accessor().removeFreeLeaf(head_id);
    try std.testing.expectEqual(@as(?u32, tail_id), freeLeafRoot(&suite.store_mgr));
    try suite.model.accessor().removeFreeLeaf(tail_id);
    try std.testing.expectEqual(@as(?u32, null), freeLeafRoot(&suite.store_mgr));
}

test "RadixTree paged: full leaves unlink from the free list" {
    const TestSuiteType = TestSuite(u32, NoneStorageManager, u64, [8]u8);
    var suite = TestSuiteType{};
    try suite.initInPlace();
    defer suite.deinit();

    const leaf_base = suite.model.effectiveSettings().leaf_base;
    try suite.tree.set(0, "first");
    const tail_id = freeLeafRoot(&suite.store_mgr).?;
    try suite.tree.set(leaf_base, "second");
    const full_id = freeLeafRoot(&suite.store_mgr).?;
    try suite.tree.set(@as(u64, leaf_base) * 2, "third");
    const head_id = freeLeafRoot(&suite.store_mgr).?;

    for (1..leaf_base) |offset| {
        try suite.tree.set(@as(u64, leaf_base) + offset, "full");
    }

    try std.testing.expectEqual(@as(?u32, head_id), freeLeafRoot(&suite.store_mgr));
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
    suite.store_mgr.state_value.free_leaf_root.set(leaf_id);

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
    try std.testing.expectEqual(@as(?u32, leaf_id), freeLeafRoot(&suite.store_mgr));
    try std.testing.expectEqual(@as(u32, free_leaf_id), blk: {
        const listed_view = View(u32, u16, u64, 8, .little, true).LeafSubheaderView.init(try leaf_page.data());
        break :blk (try listed_view.getNextFreeLeaf()).?;
    });
    try std.testing.expectEqual(@as(usize, 0), suite.store_mgr.active_leases);
}
