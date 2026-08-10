const std = @import("std");
const fullaz = @import("fullaz");

const Device = fullaz.device.MemoryBlock(u32);
const Cache = fullaz.storage.page_cache.PageCache(Device);
const TreeImpl = fullaz.spatial.orthtree.tree.TreeImpl;
const PackedInt = fullaz.core.packed_int.PackedInt;
const model_interfaces = fullaz.spatial.orthtree.models.interfaces;
const FsmModel = fullaz.storage.fsm.models.Memory(u32, u16);
const Fsm = fullaz.storage.fsm.Fsm(FsmModel);

const StorageManager = struct {
    pub const PageId = u32;
    pub const NodeId = fullaz.spatial.orthtree.models.paged.NodeId(PageId, u16);
    pub const Error = error{};

    root: ?NodeId = null,
    entries_count: usize = 0,
    fsm_roots: [256]?PageId = .{null} ** 256,

    pub fn getRoot(self: *const @This()) ?NodeId {
        return self.root;
    }

    pub fn setRoot(self: *@This(), root: ?NodeId) Error!void {
        self.root = root;
    }

    pub fn destroyPage(_: *@This(), _: PageId) Error!void {}

    pub fn getEntriesCount(self: *const @This()) Error!usize {
        return self.entries_count;
    }

    pub fn setEntriesCount(self: *@This(), count: usize) Error!void {
        self.entries_count = count;
    }

    pub fn getSizeClassRoot(self: *const @This(), class: u16) Error!?PageId {
        return self.fsm_roots[class];
    }

    pub fn setSizeClassRoot(self: *@This(), class: u16, root: ?PageId) Error!void {
        self.fsm_roots[class] = root;
    }
};

const FsmSizePolicy = struct {
    pub const SizeClass = u16;

    pub fn getSizeClass(_: *const @This(), size: SizeClass) !SizeClass {
        return size >> 8;
    }

    pub fn count(_: *const @This()) usize {
        return 256;
    }
};

const NodeLocationAccessor = fullaz.spatial.orthtree.models.paged.NodePageLocationAccessor(u32, u16, .little);
const PersistentFsmModel = fullaz.storage.fsm.models.paged.slab.Model(Cache, StorageManager, FsmSizePolicy, NodeLocationAccessor);
const PersistentFsm = fullaz.storage.fsm.Fsm(PersistentFsmModel);

test "OrthTree paged model: storage manager contract uses NodeId roots" {
    comptime model_interfaces.requiresPagedStorageManager(StorageManager, StorageManager.NodeId);
}

fn CountTrait(comptime CoordT: type, comptime dims: usize, comptime ValueT: type) type {
    comptime {
        if (ValueT != []const u8) {
            @compileError("CountTrait requires byte values");
        }
    }

    return struct {
        pub const Storage = extern struct {
            count: PackedInt(u32, .little),
        };
        pub const Error = error{};
        pub const Box = fullaz.spatial.BoundingBox(CoordT, dims);
        pub const Value = ValueT;

        pub fn format(storage: *Storage) void {
            storage.count.set(0);
        }

        pub fn validate(_: *const Storage) bool {
            return true;
        }

        pub fn onInsert(storage: *Storage, _: Box, _: Value) Error!void {
            storage.count.set(storage.count.get() + 1);
        }

        pub fn onGrow(storage: *Storage, old: *const Storage) Error!void {
            storage.* = old.*;
        }

        pub fn onAdopt(storage: *Storage, _: Box, _: Value) Error!void {
            storage.count.set(storage.count.get() + 1);
        }

        pub fn onRemove(storage: *Storage, _: Box, _: Value) Error!void {
            storage.count.set(storage.count.get() - 1);
        }
    };
}

test "OrthTree paged model: structural nodes persist through accessor loads" {
    const Model = fullaz.spatial.orthtree.models.Paged(Cache, StorageManager, Fsm, i32, 2, .little);
    const Box = Model.Box;

    var device = try Device.init(std.testing.allocator, 1024);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 8);
    defer cache.deinit();
    var storage_manager = StorageManager{};
    var fsm_model = try FsmModel.init(std.testing.allocator);
    defer fsm_model.deinit();
    var fsm = Fsm.init(&fsm_model);
    defer fsm.deinit();
    var model = try Model.init(&cache, &storage_manager, &fsm, .{
        .max_leaf_entries = 4,
        .max_value_size = 64,
        .node_layout_id = 0x1001,
        .node_page_kind = 0x71,
        .entry_page_kind = 0x72,
    });
    defer model.deinit();

    const accessor = model.getAccessor();
    var root = try accessor.createNode(Box.create(.{ 0, 0 }, .{ 10, 10 }));
    defer accessor.deinitNode(&root);
    const root_id = root.id();
    try accessor.setRoot(root_id);

    var child = try accessor.createNode(Box.create(.{ 0, 0 }, .{ 5, 5 }));
    defer accessor.deinitNode(&child);
    try std.testing.expectEqual(root.id().page_id, child.id().page_id);
    try std.testing.expect(root.id().slot_id != child.id().slot_id);
    try std.testing.expectEqual(@as(?u32, root.id().page_id), try fsm.find(1));
    try child.setParent(root_id);
    try child.setLevel(1);
    try root.beforeSplit();
    try root.setChild(0, child.id());

    try model.incrementEntriesCount();
    try model.incrementEntriesCount();
    try std.testing.expectEqual(@as(usize, 2), try model.getEntriesCount());
    try model.decrementEntriesCount();
    try std.testing.expectEqual(@as(usize, 1), try model.getEntriesCount());

    var loaded_root = try accessor.loadNode(root_id);
    defer accessor.deinitNode(&loaded_root);
    try std.testing.expect(!loaded_root.isLeaf());
    try std.testing.expectEqualDeep(child.id(), loaded_root.getChild(0).?);
    try std.testing.expect(std.meta.eql(Box.create(.{ 0, 0 }, .{ 10, 10 }), loaded_root.bounds()));

    var loaded_child = try accessor.loadNode(child.id());
    defer accessor.deinitNode(&loaded_child);
    try std.testing.expectEqualDeep(root_id, (try loaded_child.getParent()).?);
    try std.testing.expectEqual(@as(usize, 1), loaded_child.getLevel());
}

test "OrthTree paged model: rejects incompatible runtime settings" {
    const Model = fullaz.spatial.orthtree.models.Paged(Cache, StorageManager, Fsm, i32, 2, .little);

    var device = try Device.init(std.testing.allocator, 1024);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 8);
    defer cache.deinit();
    var storage_manager = StorageManager{};
    var fsm_model = try FsmModel.init(std.testing.allocator);
    defer fsm_model.deinit();
    var fsm = Fsm.init(&fsm_model);
    defer fsm.deinit();

    try std.testing.expectError(error.InvalidSettings, Model.init(&cache, &storage_manager, &fsm, .{
        .max_leaf_entries = 0,
        .max_value_size = 64,
        .node_layout_id = 0x1001,
    }));
    try std.testing.expectError(error.InvalidSettings, Model.init(&cache, &storage_manager, &fsm, .{
        .max_leaf_entries = 4,
        .max_value_size = 64,
        .node_layout_id = 0x1001,
        .node_page_kind = 7,
        .entry_page_kind = 7,
    }));
}

test "OrthTree paged model: inserts, queries, and removes byte values" {
    const Model = fullaz.spatial.orthtree.models.Paged(Cache, StorageManager, Fsm, i32, 2, .little);
    const Tree = TreeImpl(Model);
    const Box = Model.Box;
    const Collector = struct {
        seen_first: bool = false,
        seen_second: bool = false,

        fn collect(self: *@This(), _: Box, value: []const u8) !void {
            if (std.mem.eql(u8, value, "first")) {
                self.seen_first = true;
            }
            if (std.mem.eql(u8, value, "second")) {
                self.seen_second = true;
            }
        }
    };
    const MatchSecond = struct {
        fn call(_: *@This(), _: Box, value: []const u8) !bool {
            return std.mem.eql(u8, value, "second");
        }
    };

    var device = try Device.init(std.testing.allocator, 1024);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 8);
    defer cache.deinit();
    var storage_manager = StorageManager{};
    var fsm_model = try FsmModel.init(std.testing.allocator);
    defer fsm_model.deinit();
    var fsm = Fsm.init(&fsm_model);
    defer fsm.deinit();
    var model = try Model.init(&cache, &storage_manager, &fsm, .{
        .max_leaf_entries = 4,
        .max_value_size = 64,
        .node_layout_id = 0x1001,
        .node_page_kind = 0x71,
        .entry_page_kind = 0x72,
    });
    defer model.deinit();
    var tree = Tree.init(&model);
    try tree.initRootBounds(Box.create(.{ 0, 0 }, .{ 100, 100 }));

    try tree.insert(Box.create(.{ 1, 1 }, .{ 2, 2 }), "first");
    try tree.insert(Box.create(.{ 3, 3 }, .{ 4, 4 }), "second");
    try std.testing.expectEqual(@as(usize, 2), try model.getEntriesCount());

    var collector = Collector{};
    try tree.query(Box.create(.{ 0, 0 }, .{ 10, 10 }), Collector.collect, &collector);
    try std.testing.expect(collector.seen_first);
    try std.testing.expect(collector.seen_second);

    var matcher = MatchSecond{};
    try std.testing.expect(try tree.remove(Box.create(.{ 0, 0 }, .{ 10, 10 }), MatchSecond.call, &matcher));
    try std.testing.expectEqual(@as(usize, 1), try model.getEntriesCount());

    collector = .{};
    try tree.query(Box.create(.{ 0, 0 }, .{ 10, 10 }), Collector.collect, &collector);
    try std.testing.expect(collector.seen_first);
    try std.testing.expect(!collector.seen_second);
}

test "OrthTree paged model: center-crossing entries span entry chunks" {
    const Model = fullaz.spatial.orthtree.models.Paged(Cache, StorageManager, Fsm, i32, 2, .little);
    const Tree = TreeImpl(Model);
    const Box = Model.Box;
    const Counter = struct {
        count: usize = 0,

        fn collect(self: *@This(), _: Box, _: []const u8) !void {
            self.count += 1;
        }
    };

    var device = try Device.init(std.testing.allocator, 128);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 32);
    defer cache.deinit();
    var storage_manager = StorageManager{};
    var fsm_model = try FsmModel.init(std.testing.allocator);
    defer fsm_model.deinit();
    var fsm = Fsm.init(&fsm_model);
    defer fsm.deinit();
    var model = try Model.init(&cache, &storage_manager, &fsm, .{
        .max_leaf_entries = 1,
        .max_value_size = 24,
        .node_layout_id = 0x1001,
        .node_page_kind = 0x71,
        .entry_page_kind = 0x72,
    });
    defer model.deinit();
    var tree = Tree.init(&model);
    try tree.initRootBounds(Box.create(.{ 0, 0 }, .{ 100, 100 }));

    try tree.insert(Box.create(.{ 1, 1 }, .{ 2, 2 }), "lower");
    try tree.insert(Box.create(.{ 75, 75 }, .{ 76, 76 }), "upper");

    var payload: [24]u8 = undefined;
    const center_crossing = Box.create(.{ 45, 1 }, .{ 55, 2 });
    for (0..10) |index| {
        @memset(&payload, @intCast(index));
        try tree.insert(center_crossing, &payload);
    }
    try std.testing.expectEqual(@as(usize, 12), try model.getEntriesCount());

    const accessor = model.getAccessor();
    var root = try accessor.loadNode(storage_manager.root.?);
    defer accessor.deinitNode(&root);
    try std.testing.expect(!root.isLeaf());
    try std.testing.expectEqual(@as(usize, 10), root.size());
    const first_entry_page = (try root.getFirst()).?;
    const last_entry_page = (try root.getLast()).?;
    try std.testing.expect(first_entry_page != last_entry_page);

    var counter = Counter{};
    try tree.query(Box.create(.{ 0, 0 }, .{ 100, 100 }), Counter.collect, &counter);
    try std.testing.expectEqual(@as(usize, 12), counter.count);
}

test "OrthTree paged model: trait, entries, and root persist across cache reopen" {
    const Model = fullaz.spatial.orthtree.models.PagedImpl(Cache, StorageManager, Fsm, i32, 2, CountTrait, .little);
    const Tree = TreeImpl(Model);
    const Box = Model.Box;
    const Counter = struct {
        count: usize = 0,

        fn collect(self: *@This(), _: Box, _: []const u8) !void {
            self.count += 1;
        }
    };
    const settings: Model.Settings = .{
        .max_leaf_entries = 4,
        .max_value_size = 64,
        .node_layout_id = 0x1002,
        .node_page_kind = 0x71,
        .entry_page_kind = 0x72,
    };

    var device = try Device.init(std.testing.allocator, 1024);
    defer device.deinit();
    var storage_manager = StorageManager{};
    var fsm_model = try FsmModel.init(std.testing.allocator);
    defer fsm_model.deinit();
    var fsm = Fsm.init(&fsm_model);
    defer fsm.deinit();

    {
        var cache = try Cache.init(&device, std.testing.allocator, 8);
        defer cache.deinit();
        var model = try Model.init(&cache, &storage_manager, &fsm, settings);
        defer model.deinit();
        var tree = Tree.init(&model);
        try tree.initRootBounds(Box.create(.{ 0, 0 }, .{ 100, 100 }));
        try tree.insert(Box.create(.{ 1, 1 }, .{ 2, 2 }), "first");
        try tree.insert(Box.create(.{ 3, 3 }, .{ 4, 4 }), "second");
        try std.testing.expectEqual(@as(usize, 2), try model.getEntriesCount());
        try cache.flushAll();
    }

    {
        var cache = try Cache.init(&device, std.testing.allocator, 8);
        defer cache.deinit();
        var model = try Model.init(&cache, &storage_manager, &fsm, settings);
        defer model.deinit();
        var tree = Tree.init(&model);
        const available_before = cache.availableFrames();

        var counter = Counter{};
        try tree.query(Box.create(.{ 0, 0 }, .{ 100, 100 }), Counter.collect, &counter);
        try std.testing.expectEqual(@as(usize, 2), counter.count);
        try std.testing.expectEqual(@as(usize, 2), try model.getEntriesCount());

        {
            var root = try model.getAccessor().loadNode(storage_manager.root.?);
            defer model.getAccessor().deinitNode(&root);
            try std.testing.expectEqual(@as(u32, 2), root.getTrait().count.get());
        }

        try tree.insert(Box.create(.{ 5, 5 }, .{ 6, 6 }), "third");
        counter = .{};
        try tree.query(Box.create(.{ 0, 0 }, .{ 100, 100 }), Counter.collect, &counter);
        try std.testing.expectEqual(@as(usize, 3), counter.count);
        try std.testing.expectEqual(@as(usize, 3), try model.getEntriesCount());
        try std.testing.expectEqual(available_before, cache.availableFrames());
    }
}

test "OrthTree paged model: paged FSM reopens and reuses partially filled node pages" {
    const Model = fullaz.spatial.orthtree.models.Paged(Cache, StorageManager, PersistentFsm, i32, 2, .little);
    const Tree = TreeImpl(Model);
    const Box = Model.Box;
    const Counter = struct {
        count: usize = 0,

        fn collect(self: *@This(), _: Box, _: []const u8) !void {
            self.count += 1;
        }
    };
    const settings: Model.Settings = .{
        .max_leaf_entries = 4,
        .max_value_size = 64,
        .node_layout_id = 0x2001,
        .node_page_kind = 0x71,
        .entry_page_kind = 0x72,
    };

    var device = try Device.init(std.testing.allocator, 256);
    defer device.deinit();
    var storage_manager = StorageManager{};
    var spilled_page_id: u32 = undefined;

    {
        var cache = try Cache.init(&device, std.testing.allocator, 32);
        defer cache.deinit();
        var fsm_model = PersistentFsmModel.init(&cache, &storage_manager, FsmSizePolicy{}, .{ .page_kind = 0x73 });
        var fsm = PersistentFsm.init(&fsm_model);
        defer fsm.deinit();
        var model = try Model.init(&cache, &storage_manager, &fsm, settings);
        defer model.deinit();
        const accessor = model.getAccessor();

        {
            var root = try accessor.createNode(Box.create(.{ 0, 0 }, .{ 100, 100 }));
            defer accessor.deinitNode(&root);
            try accessor.setRoot(root.id());
            var node1 = try accessor.createNode(Box.create(.{ 0, 0 }, .{ 10, 10 }));
            defer accessor.deinitNode(&node1);
            var node2 = try accessor.createNode(Box.create(.{ 10, 10 }, .{ 20, 20 }));
            defer accessor.deinitNode(&node2);
            var node3 = try accessor.createNode(Box.create(.{ 20, 20 }, .{ 30, 30 }));
            defer accessor.deinitNode(&node3);

            try std.testing.expectEqual(root.id().page_id, node1.id().page_id);
            try std.testing.expectEqual(root.id().page_id, node2.id().page_id);
            try std.testing.expect(node3.id().page_id != root.id().page_id);
            spilled_page_id = node3.id().page_id;

            var tree = Tree.init(&model);
            try tree.insert(Box.create(.{ 1, 1 }, .{ 2, 2 }), "persisted");
        }

        {
            var root_page = try cache.fetch(storage_manager.root.?.page_id);
            defer root_page.deinit();
            try std.testing.expect((try NodeLocationAccessor.read(try root_page.getData())) != null);
        }
        try cache.flushAll();
    }

    {
        var cache = try Cache.init(&device, std.testing.allocator, 32);
        defer cache.deinit();
        var fsm_model = PersistentFsmModel.init(&cache, &storage_manager, FsmSizePolicy{}, .{ .page_kind = 0x73 });
        var fsm = PersistentFsm.init(&fsm_model);
        defer fsm.deinit();
        var model = try Model.init(&cache, &storage_manager, &fsm, settings);
        defer model.deinit();
        var tree = Tree.init(&model);
        const available_before = cache.availableFrames();

        var counter = Counter{};
        try tree.query(Box.create(.{ 0, 0 }, .{ 100, 100 }), Counter.collect, &counter);
        try std.testing.expectEqual(@as(usize, 1), counter.count);

        const accessor = model.getAccessor();
        try std.testing.expectError(error.OutOfBounds, accessor.loadNode(.{ .page_id = spilled_page_id, .slot_id = 1 }));
        {
            var reused = try accessor.createNode(Box.create(.{ 30, 30 }, .{ 40, 40 }));
            defer accessor.deinitNode(&reused);
            try std.testing.expectEqual(spilled_page_id, reused.id().page_id);
        }
        try std.testing.expectEqual(available_before, cache.availableFrames());
    }
}

test "OrthTree paged model: loader rejects a mismatched self pid without leaking frames" {
    const Model = fullaz.spatial.orthtree.models.Paged(Cache, StorageManager, Fsm, i32, 2, .little);
    const Tree = TreeImpl(Model);
    const Box = Model.Box;
    const HeaderView = fullaz.page.header.View(u32, u16, .little, false);

    var device = try Device.init(std.testing.allocator, 1024);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 8);
    defer cache.deinit();
    var storage_manager = StorageManager{};
    var fsm_model = try FsmModel.init(std.testing.allocator);
    defer fsm_model.deinit();
    var fsm = Fsm.init(&fsm_model);
    defer fsm.deinit();
    var model = try Model.init(&cache, &storage_manager, &fsm, .{
        .max_leaf_entries = 4,
        .max_value_size = 64,
        .node_layout_id = 0x1001,
        .node_page_kind = 0x71,
        .entry_page_kind = 0x72,
    });
    defer model.deinit();
    var tree = Tree.init(&model);
    try tree.initRootBounds(Box.create(.{ 0, 0 }, .{ 100, 100 }));

    const root_id = storage_manager.root.?;
    var page = try cache.fetch(root_id.page_id);
    defer page.deinit();
    var header_view = HeaderView.init(try page.getDataMut());
    header_view.headerMut().self_pid.set(root_id.page_id + 1);

    const available_before = cache.availableFrames();
    try std.testing.expectError(error.BadData, model.getAccessor().loadNode(root_id));
    try std.testing.expectEqual(available_before, cache.availableFrames());
}

test "OrthTree paged model: loader rejects incompatible node page metadata without leaking frames" {
    const Model = fullaz.spatial.orthtree.models.Paged(Cache, StorageManager, Fsm, i32, 2, .little);
    const Tree = TreeImpl(Model);
    const Box = Model.Box;
    const PackedView = fullaz.spatial.orthtree.models.paged.PackedView(u32, u16, i32, 2, Model.Trait, .little, false);
    const layout_id: u32 = 0x1001;

    var device = try Device.init(std.testing.allocator, 1024);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 8);
    defer cache.deinit();
    var storage_manager = StorageManager{};
    var fsm_model = try FsmModel.init(std.testing.allocator);
    defer fsm_model.deinit();
    var fsm = Fsm.init(&fsm_model);
    defer fsm.deinit();
    var model = try Model.init(&cache, &storage_manager, &fsm, .{
        .max_leaf_entries = 4,
        .max_value_size = 64,
        .node_layout_id = layout_id,
        .node_page_kind = 0x71,
        .entry_page_kind = 0x72,
    });
    defer model.deinit();
    var tree = Tree.init(&model);
    try tree.initRootBounds(Box.create(.{ 0, 0 }, .{ 100, 100 }));

    const root_id = storage_manager.root.?;
    var page = try cache.fetch(root_id.page_id);
    defer page.deinit();
    var node_page = PackedView.NodePage.init(try page.getDataMut());
    node_page.subheaderMut().layout_id.set(layout_id + 1);

    const available_before = cache.availableFrames();
    try std.testing.expectError(error.BadData, model.getAccessor().loadNode(root_id));
    try std.testing.expectEqual(available_before, cache.availableFrames());

    node_page.subheaderMut().layout_id.set(layout_id);
    node_page.subheaderMut().fsm_location.page_id.set(1);
    node_page.subheaderMut().fsm_location.slot_id.setMax();
    try std.testing.expectError(error.BadData, model.getAccessor().loadNode(root_id));
    try std.testing.expectEqual(available_before, cache.availableFrames());
}

// Every other paged-model test here is (i32, 2). These two are the first to put
// three dimensions and a float coordinate through the page layout, the trait
// contract and the entry codec.
const Cube = struct {
    const Model = fullaz.spatial.orthtree.models.PagedImpl(Cache, StorageManager, Fsm, f32, 3, CountTrait, .little);
    const Tree = TreeImpl(Model);
    const Box = Model.Box;
    const Format = fullaz.page.orthtree.Orthtree(u32, u16, f32, 3, .little);

    const side: f32 = 65536.0;
    const page_size: usize = 1024;
    const frames: usize = 64;

    const settings: Model.Settings = .{
        .max_leaf_entries = 24,
        .max_value_size = 16,
        .max_tree_depth = 16,
        .node_layout_id = 0x3D01,
        .node_page_kind = 0x75,
        .entry_page_kind = 0x76,
    };

    fn rootBox() Box {
        return Box.create(.{ 0, 0, 0 }, .{ side, side, side });
    }

    fn point(p: [3]f32) Box {
        return Box.create(p, p);
    }

    // Strictly inside the cube: a coordinate of exactly 0 would make the
    // degenerate entry box fail the half-open overlap test in queryNode.
    fn sample(index: u32) [3]f32 {
        var prng = std.Random.DefaultPrng.init(0x5EED0000 + @as(u64, index));
        const r = prng.random();
        const span = side - 2.0;
        return .{
            1.0 + r.float(f32) * span,
            1.0 + r.float(f32) * span,
            1.0 + r.float(f32) * span,
        };
    }
};

test "OrthTree paged model: three dimensional f32 nodes round-trip through pages" {
    const C = Cube;

    try std.testing.expectEqual(@as(usize, 94), @sizeOf(C.Format.NodeSlotSubheader));
    try std.testing.expectEqual(@as(usize, 8), C.Tree.child_count);

    var device = try Device.init(std.testing.allocator, C.page_size);
    defer device.deinit();
    var storage_manager = StorageManager{};
    var fsm_model = try FsmModel.init(std.testing.allocator);
    defer fsm_model.deinit();
    var fsm = Fsm.init(&fsm_model);
    defer fsm.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, C.frames);
    defer cache.deinit();
    var model = try C.Model.init(&cache, &storage_manager, &fsm, C.settings);
    defer model.deinit();

    const accessor = model.getAccessor();
    const bounds = C.Box.create(.{ 1.5, -2.25, 3.125 }, .{ 9.5, 10.75, 11.0 });
    const node_id = blk: {
        var node = try accessor.createNode(bounds);
        defer accessor.deinitNode(&node);
        break :blk node.id();
    };

    var loaded = try accessor.loadNode(node_id);
    defer accessor.deinitNode(&loaded);

    // PackedFloat is bit-preserving, so the page round-trip must be exact.
    try std.testing.expectEqual(bounds.low, loaded.bounds().low);
    try std.testing.expectEqual(bounds.high, loaded.bounds().high);
}

test "OrthTree paged model: three dimensional f32 insert, split, and reopen" {
    const C = Cube;
    const count: u32 = 2000;

    var device = try Device.init(std.testing.allocator, C.page_size);
    defer device.deinit();
    var storage_manager = StorageManager{};
    var fsm_model = try FsmModel.init(std.testing.allocator);
    defer fsm_model.deinit();
    var fsm = Fsm.init(&fsm_model);
    defer fsm.deinit();

    {
        var cache = try Cache.init(&device, std.testing.allocator, C.frames);
        defer cache.deinit();
        var model = try C.Model.init(&cache, &storage_manager, &fsm, C.settings);
        defer model.deinit();
        var tree = C.Tree.init(&model);
        try tree.initRootBounds(C.rootBox());

        const available_before = cache.availableFrames();
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            try tree.insert(C.point(C.sample(i)), "p");
        }
        try std.testing.expectEqual(available_before, cache.availableFrames());
        try std.testing.expectEqual(@as(usize, count), try model.getEntriesCount());

        const Probe = struct {
            nodes: usize = 0,
            min_extent: f32 = C.side,

            fn onNode(
                self: *@This(),
                _: anytype,
                b: C.Box,
                _: *const C.Model.Trait,
                _: bool,
            ) !fullaz.spatial.orthtree.tree.TraverseDecision {
                self.nodes += 1;
                self.min_extent = @min(self.min_extent, b.high[0] - b.low[0]);
                return .descend;
            }

            fn onEntry(_: *@This(), _: C.Box, _: []const u8) !void {}
        };
        var probe = Probe{};
        try tree.traverse(Probe.onNode, Probe.onEntry, &probe);

        // It must have split (8 children per level), and it must not have
        // bottomed out: 2000 uniform points in a 65536 cube never need
        // sub-unit cells, so reaching them would mean subdivision degenerated.
        try std.testing.expect(probe.nodes > C.Tree.child_count);
        try std.testing.expect(probe.min_extent > 1.0);

        var root = try model.getAccessor().loadNode(storage_manager.root.?);
        defer model.getAccessor().deinitNode(&root);
        try std.testing.expectEqual(count, root.getTrait().count.get());

        try cache.flushAll();
    }

    {
        var cache = try Cache.init(&device, std.testing.allocator, C.frames);
        defer cache.deinit();
        var model = try C.Model.init(&cache, &storage_manager, &fsm, C.settings);
        defer model.deinit();
        var tree = C.Tree.init(&model);

        const Counter = struct {
            count: usize = 0,

            fn collect(self: *@This(), _: C.Box, _: []const u8) !void {
                self.count += 1;
            }
        };
        var counter = Counter{};
        try tree.query(C.rootBox(), Counter.collect, &counter);

        try std.testing.expectEqual(@as(usize, count), counter.count);
        try std.testing.expectEqual(@as(usize, count), try model.getEntriesCount());

        var root = try model.getAccessor().loadNode(storage_manager.root.?);
        defer model.getAccessor().deinitNode(&root);
        try std.testing.expectEqual(count, root.getTrait().count.get());
    }
}

const GrowthFixture = struct {
    const Model = fullaz.spatial.orthtree.models.PagedImpl(Cache, StorageManager, Fsm, i32, 2, CountTrait, .little);
    const Tree = TreeImpl(Model);
    const Box = Model.Box;

    fn point(x: i32, y: i32) Box {
        return Box.create(.{ x, y }, .{ x, y });
    }

    fn rootTraitCount(model: *Model, root_id: StorageManager.NodeId) !u32 {
        var root = try model.getAccessor().loadNode(root_id);
        defer model.getAccessor().deinitNode(&root);
        return root.getTrait().count.get();
    }
};

// The memory model's deinitNode is a no-op, so the growth tests in
// tests/spatial/orthtree/orthtree.zig cannot observe frame accounting at all.
// These two exercise growRootToContain against real page handles.
test "OrthTree paged model: a single root growth releases every pinned frame" {
    const F = GrowthFixture;

    var device = try Device.init(std.testing.allocator, 1024);
    defer device.deinit();
    var storage_manager = StorageManager{};
    var fsm_model = try FsmModel.init(std.testing.allocator);
    defer fsm_model.deinit();
    var fsm = Fsm.init(&fsm_model);
    defer fsm.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 32);
    defer cache.deinit();
    var model = try F.Model.init(&cache, &storage_manager, &fsm, .{
        .max_leaf_entries = 4,
        .max_value_size = 64,
        .node_layout_id = 0x1010,
        .node_page_kind = 0x71,
        .entry_page_kind = 0x72,
    });
    defer model.deinit();

    var tree = F.Tree.init(&model);
    try tree.initRootBounds(F.Box.create(.{ 0, 0 }, .{ 100, 100 }));
    try tree.insert(F.point(10, 10), "inside");

    const available_before = cache.availableFrames();

    // (150,150) needs exactly one doubling: [0,100] -> [0,200].
    try tree.insert(F.point(150, 150), "outside");

    try std.testing.expectEqual(available_before, cache.availableFrames());
    try std.testing.expectEqual(@as(usize, 2), try model.getEntriesCount());

    const bounds = (try tree.bounds()).?;
    try std.testing.expectEqual(@as(i32, 200), bounds.high[0]);
    try std.testing.expectEqual(@as(i32, 200), bounds.high[1]);
}

test "OrthTree paged model: repeated root growth keeps the tree usable" {
    const F = GrowthFixture;

    var device = try Device.init(std.testing.allocator, 1024);
    defer device.deinit();
    var storage_manager = StorageManager{};
    var fsm_model = try FsmModel.init(std.testing.allocator);
    defer fsm_model.deinit();
    var fsm = Fsm.init(&fsm_model);
    defer fsm.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 32);
    defer cache.deinit();
    var model = try F.Model.init(&cache, &storage_manager, &fsm, .{
        .max_leaf_entries = 4,
        .max_value_size = 64,
        .node_layout_id = 0x1011,
        .node_page_kind = 0x71,
        .entry_page_kind = 0x72,
    });
    defer model.deinit();

    var tree = F.Tree.init(&model);
    try tree.initRootBounds(F.Box.create(.{ 0, 0 }, .{ 100, 100 }));
    try tree.insert(F.point(10, 10), "inside");

    const available_before = cache.availableFrames();

    // (1000,1000) needs four doublings: 100 -> 200 -> 400 -> 800 -> 1600.
    try tree.insert(F.point(1000, 1000), "far");

    try std.testing.expectEqual(available_before, cache.availableFrames());
    try std.testing.expectEqual(@as(usize, 2), try model.getEntriesCount());
    try std.testing.expectEqual(
        @as(u32, 2),
        try F.rootTraitCount(&model, storage_manager.root.?),
    );

    const bounds = (try tree.bounds()).?;
    try std.testing.expectEqual(@as(i32, 1600), bounds.high[0]);
    try std.testing.expectEqual(@as(i32, 1600), bounds.high[1]);

    const Counter = struct {
        count: usize = 0,

        fn collect(self: *@This(), _: F.Box, _: []const u8) !void {
            self.count += 1;
        }
    };
    var counter = Counter{};
    try tree.query(F.Box.create(.{ 0, 0 }, .{ 1600, 1600 }), Counter.collect, &counter);
    try std.testing.expectEqual(@as(usize, 2), counter.count);
}
