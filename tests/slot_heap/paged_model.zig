const std = @import("std");
const fullaz = @import("fullaz");

fn compare(_: void, left: []const u8, right: []const u8) std.math.Order {
    return std.mem.order(u8, left, right);
}

const Device = fullaz.device.MemoryBlock(u32);
const PageCache = fullaz.storage.page_cache.PageCache(Device);
const FsmModel = fullaz.storage.fsm.models.Memory(u32, u16);
const Fsm = fullaz.storage.fsm.Fsm(FsmModel);
const WideFsmModel = fullaz.storage.fsm.models.Memory(u32, u32);
const WideFsm = fullaz.storage.fsm.Fsm(WideFsmModel);
const SizePolicy = fullaz.storage.fsm.size_classes.One;
const State = fullaz.storage.slot_heap.models.paged.State(u32, u16, 32, SizePolicy);

const StorageManager = struct {
    pub const PageId = u32;
    pub const Error = std.mem.Allocator.Error;
    pub const StateLeaseType = struct {
        const Self = @This();

        pub const Error = StorageManager.Error;

        value: *State,

        pub fn data(self: *const Self) Self.Error![]const u8 {
            return std.mem.asBytes(@as(*const State, self.value));
        }

        pub fn dataMut(self: *Self) Self.Error![]u8 {
            return std.mem.asBytes(self.value);
        }

        pub fn finish(_: *Self) void {}

        pub fn deinit(_: *Self) void {}
    };

    state_value: State = .{},
    destroyed: std.ArrayList(PageId) = .empty,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) @This() {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *@This()) void {
        self.destroyed.deinit(self.allocator);
    }

    pub fn state(self: *@This()) Error!StateLeaseType {
        return .{ .value = &self.state_value };
    }

    pub fn destroyPage(self: *@This(), page_id: PageId) Error!void {
        self.destroyed.append(self.allocator, page_id) catch unreachable;
    }
};

const HeapStateManager = fullaz.core.storage_manager.PagedFieldStorageManager(
    StorageManager,
    State,
    "heap",
);

const Model = fullaz.storage.slot_heap.models.Paged(
    PageCache,
    HeapStateManager,
    32,
    Fsm,
    compare,
    void,
);
const Heap = fullaz.storage.slot_heap.Heap(Model);
const WideModel = fullaz.storage.slot_heap.models.Paged(
    PageCache,
    HeapStateManager,
    32,
    WideFsm,
    compare,
    void,
);

const TestContext = struct {
    device: Device,
    cache: PageCache,
    storage_manager: StorageManager,
    heap_state_manager: HeapStateManager,
    fsm_model: FsmModel,
    fsm: Fsm,
    model: Model,

    fn initInPlace(self: *@This(), page_size: usize) !void {
        self.device = try Device.init(std.testing.allocator, page_size);
        errdefer self.device.deinit();
        self.cache = try PageCache.init(&self.device, std.testing.allocator, 32);
        errdefer self.cache.deinit();
        self.storage_manager = StorageManager.init(std.testing.allocator);
        errdefer self.storage_manager.deinit();
        self.heap_state_manager = HeapStateManager.init(&self.storage_manager);
        self.fsm_model = try FsmModel.init(std.testing.allocator);
        errdefer self.fsm_model.deinit();
        self.fsm = Fsm.init(&self.fsm_model);
        self.model = try Model.init(
            &self.cache,
            &self.heap_state_manager,
            &self.fsm,
            .{
                .key_size = 4,
                .maximum_value_size = 12,
                .comparator_id = 71,
                .leaf_page_kind = 41,
                .inode_page_kind = 42,
            },
            {},
        );
    }

    fn deinit(self: *@This()) void {
        self.model.deinit();
        self.fsm.deinit();
        self.fsm_model.deinit();
        self.storage_manager.deinit();
        self.cache.deinit();
        self.device.deinit();
    }

    fn restartCache(self: *@This()) !void {
        self.cache.deinit();
        self.cache = try PageCache.init(&self.device, std.testing.allocator, 32);
    }
};

test "SlotHeap paged model: contract and settings" {
    comptime fullaz.storage.slot_heap.models.interfaces.assertModel(Model);

    var device = try Device.init(std.testing.allocator, 128);
    defer device.deinit();
    var cache = try PageCache.init(&device, std.testing.allocator, 4);
    defer cache.deinit();
    var storage_manager = StorageManager.init(std.testing.allocator);
    defer storage_manager.deinit();
    var heap_state_manager = HeapStateManager.init(&storage_manager);
    var fsm_model = try FsmModel.init(std.testing.allocator);
    defer fsm_model.deinit();
    var fsm = Fsm.init(&fsm_model);
    defer fsm.deinit();

    try std.testing.expectError(error.InvalidSettings, Model.init(
        &cache,
        &heap_state_manager,
        &fsm,
        .{ .key_size = 0, .maximum_value_size = 1, .comparator_id = 1 },
        {},
    ));
    try std.testing.expectError(error.InvalidSettings, Model.init(
        &cache,
        &heap_state_manager,
        &fsm,
        .{
            .key_size = 4,
            .maximum_value_size = 1,
            .comparator_id = 1,
            .leaf_page_kind = 3,
            .inode_page_kind = 3,
        },
        {},
    ));

    var large_device = try Device.init(std.testing.allocator, 65_536);
    defer large_device.deinit();
    var large_cache = try PageCache.init(&large_device, std.testing.allocator, 1);
    defer large_cache.deinit();
    var wide_fsm_model = try WideFsmModel.init(std.testing.allocator);
    defer wide_fsm_model.deinit();
    var wide_fsm = WideFsm.init(&wide_fsm_model);
    defer wide_fsm.deinit();
    try std.testing.expectError(error.InvalidSettings, WideModel.init(
        &large_cache,
        &heap_state_manager,
        &wide_fsm,
        .{ .key_size = 4, .maximum_value_size = 1, .comparator_id = 1 },
        {},
    ));
}

test "SlotHeap paged model: leaf and inode operations survive reload" {
    var ctx: TestContext = undefined;
    try ctx.initInPlace(192);
    defer ctx.deinit();
    const accessor = ctx.model.accessor();

    var leaf = try accessor.createLeaf();
    const leaf_id = leaf.id();
    try std.testing.expectEqual(@as(usize, 0), try leaf.usedBytes());
    try std.testing.expectEqual(
        try leaf.capacityBytes(),
        try leaf.usedBytes() + try leaf.availableAfterCompact(),
    );
    try std.testing.expectEqual(@as(u16, 11), try ctx.model.requiredLeafSpace("0000", "odd"));
    _ = try leaf.push("0003", "three");
    try std.testing.expectEqual(.changed, try leaf.push("0001", "one"));
    _ = try leaf.push("0002", "two");
    try std.testing.expectEqualSlices(u8, "0001", try leaf.getKey(0));
    try leaf.popTop();
    try std.testing.expectEqual(
        try leaf.capacityBytes(),
        try leaf.usedBytes() + try leaf.availableAfterCompact(),
    );
    accessor.deinitLeaf(leaf);
    try ctx.restartCache();

    var loaded_leaf = (try accessor.loadLeaf(leaf_id)).?;
    try std.testing.expectEqualSlices(u8, "0002", try loaded_leaf.getKey(0));
    accessor.deinitLeaf(loaded_leaf);

    var inode = try accessor.createInode(1);
    const inode_id = inode.id();
    _ = try inode.insertChild("0003", 103, .{ .page_id = leaf_id, .slot_id = 0 });
    _ = try inode.insertChild("0001", 101, .{ .page_id = leaf_id, .slot_id = 0 });
    _ = try inode.insertChild("0002", 102, .{ .page_id = leaf_id, .slot_id = 0 });
    try std.testing.expectEqual(@as(u32, 101), try inode.getChild(0));
    _ = try inode.updateChild(0, "0004", .{ .page_id = leaf_id, .slot_id = 0 });
    try std.testing.expectEqualSlices(u8, "0002", try inode.getKey(0));
    _ = try inode.removeChild(0);
    accessor.deinitInode(inode);
    try ctx.restartCache();

    var loaded_inode = (try accessor.loadInode(inode_id)).?;
    defer accessor.deinitInode(loaded_inode);
    try std.testing.expectEqual(@as(usize, 2), try loaded_inode.size());
}

test "SlotHeap paged model: opposite page kinds return null" {
    var ctx: TestContext = undefined;
    try ctx.initInPlace(192);
    defer ctx.deinit();
    const accessor = ctx.model.accessor();

    var leaf = try accessor.createLeaf();
    const leaf_id = leaf.id();
    accessor.deinitLeaf(leaf);
    var inode = try accessor.createInode(1);
    const inode_id = inode.id();
    accessor.deinitInode(inode);

    try std.testing.expectEqual(@as(?Model.LeafType, null), try accessor.loadLeaf(inode_id));
    try std.testing.expectEqual(@as(?Model.InodeType, null), try accessor.loadInode(leaf_id));
}

test "SlotHeap paged model: foreign and corrupt pages fail loading" {
    var ctx: TestContext = undefined;
    try ctx.initInPlace(192);
    defer ctx.deinit();
    const accessor = ctx.model.accessor();

    var foreign_handle = try ctx.cache.create();
    const foreign_id = try foreign_handle.pid();
    var foreign_view = fullaz.page.header.View(u32, u16, .little, false).init(
        try foreign_handle.dataMut(),
    );
    foreign_view.formatPage(99, foreign_id, 0, 0);
    foreign_handle.deinit();
    try std.testing.expectError(error.BadType, accessor.loadLeaf(foreign_id));

    var leaf = try accessor.createLeaf();
    const leaf_id = leaf.id();
    accessor.deinitLeaf(leaf);
    var corrupt_handle = try ctx.cache.fetch(leaf_id);
    var corrupt_view = fullaz.page.header.View(u32, u16, .little, false).init(
        try corrupt_handle.dataMut(),
    );
    corrupt_view.headerMut().page_end.set(0);
    corrupt_handle.deinit();
    try std.testing.expectError(error.InvalidPageEnd, accessor.loadLeaf(leaf_id));
}

test "SlotHeap paged model: generic heap grows, orders, and cleans up" {
    var ctx: TestContext = undefined;
    try ctx.initInPlace(128);
    defer ctx.deinit();
    var heap = Heap.init(&ctx.model);

    var keys: [100][4]u8 = undefined;
    for (0..keys.len) |index| {
        _ = try std.fmt.bufPrint(&keys[index], "{d:0>4}", .{keys.len - index});
        try heap.push(&keys[index], "v");
    }
    try std.testing.expect((try heap.height()) >= 2);

    for (1..keys.len + 1) |expected| {
        var expected_key: [4]u8 = undefined;
        _ = try std.fmt.bufPrint(&expected_key, "{d:0>4}", .{expected});
        var top = try heap.top();
        try std.testing.expectEqualSlices(u8, &expected_key, try top.key());
        top.deinit();
        try heap.pop();
    }

    try std.testing.expect(ctx.storage_manager.state_value.heap.root.isMax());
    try std.testing.expect(ctx.storage_manager.state_value.heap.cached_top_page.isMax());
    try std.testing.expect(ctx.storage_manager.state_value.heap.cached_top_slot.isMax());
    try std.testing.expectEqual(@as(u64, 0), ctx.storage_manager.state_value.heap.entries_count.get());
    try std.testing.expectEqual(@as(usize, 0), ctx.fsm_model.entries.items.len);
    try std.testing.expect(ctx.storage_manager.destroyed.items.len > 0);
    for (ctx.storage_manager.destroyed.items, 0..) |page_id, index| {
        for (ctx.storage_manager.destroyed.items[index + 1 ..]) |other_page_id| {
            try std.testing.expect(page_id != other_page_id);
        }
    }
    for (ctx.storage_manager.state_value.heap.available_inode_heads) |head| {
        try std.testing.expect(head.isMax());
    }
}

test "SlotHeap paged: top value editor preserves heap metadata and rolls back" {
    var ctx: TestContext = undefined;
    try ctx.initInPlace(192);
    defer ctx.deinit();
    var heap = Heap.init(&ctx.model);
    try heap.push("0002", "two");
    try heap.push("0001", "one");
    const root = ctx.storage_manager.state_value.heap.root;
    const cached_top = ctx.storage_manager.state_value.heap.cached_top_page;
    const fsm_entries = ctx.fsm_model.entries.items.len;

    var editor = try heap.openValueEditor();
    @memcpy(try editor.valueMut(), "ONE");
    try std.testing.expectError(error.ValueEditorActive, heap.openValueEditor());
    try std.testing.expectError(error.ValueEditorActive, heap.pop());
    try std.testing.expectError(error.ValueEditorActive, heap.clear());
    try editor.finish();
    try std.testing.expectError(error.EditorInvalidated, editor.valueMut());
    editor.deinit();

    try std.testing.expectEqual(root, ctx.storage_manager.state_value.heap.root);
    try std.testing.expectEqual(cached_top, ctx.storage_manager.state_value.heap.cached_top_page);
    try std.testing.expectEqual(fsm_entries, ctx.fsm_model.entries.items.len);
    try std.testing.expectEqual(@as(u64, 2), try heap.count());
    var top = try heap.top();
    try std.testing.expectEqualSlices(u8, "0001", try top.key());
    try std.testing.expectEqualSlices(u8, "ONE", try top.value());
    top.deinit();

    var peek = try heap.mutableTop();
    var rollback = try peek.editValue();
    @memcpy(try rollback.valueMut(), "bad");
    rollback.deinit();
    peek.deinit();
    top = try heap.top();
    defer top.deinit();
    try std.testing.expectEqualSlices(u8, "ONE", try top.value());
}
