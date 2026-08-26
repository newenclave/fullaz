const std = @import("std");
const fullaz = @import("fullaz");

const bpt = fullaz.bpt;
const algos = fullaz.core.algorithm;

fn MemoryStore(comptime BptModel: type) type {
    return struct {
        const Self = @This();

        pub const Error = BptModel.Error || error{InvalidPageId};
        pub const Page = struct { id: usize };

        model: *BptModel,
        page_count: usize,
        free: []bool,

        pub fn pageCount(self: *const Self) usize {
            return self.page_count;
        }

        pub fn isFree(self: *const Self, page_id: usize) Error!bool {
            if (page_id >= self.page_count) {
                return error.InvalidPageId;
            }
            return self.free[page_id];
        }

        pub fn fetchPage(self: *const Self, page_id: usize) Error!Page {
            if (page_id >= self.page_count or self.free[page_id]) {
                return error.InvalidPageId;
            }
            return .{ .id = page_id };
        }

        pub fn releasePage(_: *const Self, _: *Page) void {}

        pub fn pageKind(self: *const Self, page: *const Page, _: usize) Error!u16 {
            return if (try self.model.accessor().isLeafId(page.id)) 1 else 2;
        }

        pub fn pageData(_: *const Self, _: *const Page) Error![]const u8 {
            return &.{};
        }

        pub fn isReserved(_: *const Self, _: usize) Error!bool {
            return false;
        }

        pub fn reclaim(self: *Self, page_id: usize) Error!void {
            if (page_id >= self.page_count) {
                return error.InvalidPageId;
            }
            self.free[page_id] = true;
        }
    };
}

fn bptScanners(comptime BptModel: type, comptime Collector: type) type {
    return struct {
        fn inode(
            context: ?*const anyopaque,
            page_id: BptModel.NodeIdType,
            page: []const u8,
            sink: Collector.ReferenceSink,
        ) Collector.Error!void {
            const model: *BptModel = @ptrCast(@alignCast(@constCast(context.?)));
            model.scanInodeRefs(page_id, page, sink) catch return error.InvalidPageId;
        }

        fn leaf(
            context: ?*const anyopaque,
            page_id: BptModel.NodeIdType,
            page: []const u8,
            sink: Collector.ReferenceSink,
        ) Collector.Error!void {
            const model: *BptModel = @ptrCast(@alignCast(@constCast(context.?)));
            model.scanLeafRefs(page_id, page, sink) catch return error.InvalidPageId;
        }
    };
}

fn collectBptGraph(comptime BptModel: type, model: *BptModel, page_id: BptModel.NodeIdType, seen: []bool) !void {
    const index: usize = @intCast(page_id);
    if (seen[index]) {
        return;
    }
    seen[index] = true;

    const accessor = model.accessor();
    if (try accessor.isLeafId(page_id)) {
        const leaf = (try accessor.loadLeaf(page_id)).?;
        defer accessor.deinitLeaf(leaf);
        return;
    }

    const inode = (try accessor.loadInode(page_id)).?;
    defer accessor.deinitInode(inode);
    for (0..try inode.size() + 1) |child_index| {
        try collectBptGraph(BptModel, model, try inode.getChild(child_index), seen);
    }
}

test "GC: memory model reclaims one BPT graph and retains another" {
    const BptModel = bpt.models.MemoryModel(u32, 3, algos.CmpNum(u32).asc);
    const Tree = bpt.Bpt(BptModel);

    var bpt_model = try BptModel.init(std.testing.allocator);
    defer bpt_model.deinit();
    var first = Tree.init(&bpt_model, .force_split);
    var second = Tree.init(&bpt_model, .force_split);

    for (0..12) |index| {
        try std.testing.expect(try first.insert(@intCast(index), "dropped"));
    }
    const dropped_root = bpt_model.accessor().getRoot().?;
    try bpt_model.accessor().setRoot(null);
    for (100..112) |index| {
        try std.testing.expect(try second.insert(@intCast(index), "retained"));
    }
    const retained_root = bpt_model.accessor().getRoot().?;

    var dropped_pages = [_]bool{false} ** 64;
    var retained_pages = [_]bool{false} ** 64;
    try collectBptGraph(BptModel, &bpt_model, dropped_root, &dropped_pages);
    try collectBptGraph(BptModel, &bpt_model, retained_root, &retained_pages);
    const page_count = @max(lastSet(&dropped_pages), lastSet(&retained_pages)) + 1;
    try std.testing.expect(dropped_pages[dropped_root]);
    try std.testing.expect(retained_pages[retained_root]);

    var free = [_]bool{false} ** 64;
    var store = MemoryStore(BptModel){
        .model = &bpt_model,
        .page_count = page_count,
        .free = &free,
    };
    const GcModel = fullaz.gc.models.Memory(@TypeOf(store));
    const Collector = fullaz.gc.Gc(GcModel);
    const Scanners = bptScanners(BptModel, Collector);
    var gc_model = GcModel.init(std.testing.allocator, &store);
    defer gc_model.deinit();
    var collector = Collector.init(&gc_model);
    defer collector.deinit();
    try collector.register(1, 1, &bpt_model, Scanners.leaf, null);
    try collector.register(2, 1, &bpt_model, Scanners.inode, null);
    try collector.start(&.{retained_root});
    while (try collector.step(1) != .complete) {}

    for (dropped_pages, 0..) |was_in_graph, page_id| {
        if (was_in_graph) {
            try std.testing.expect(free[page_id]);
        }
    }
    for (retained_pages, 0..) |was_in_graph, page_id| {
        if (was_in_graph) {
            try std.testing.expect(!free[page_id]);
        }
    }
    if (try second.find(105)) |iterator| {
        defer iterator.deinit();
    } else {
        try std.testing.expect(false);
    }
}

test "GC: memory BPT leaf value scanner retains an embedded root" {
    const BptModel = bpt.models.MemoryModel(u32, 3, algos.CmpNum(u32).asc);
    const Tree = bpt.Bpt(BptModel);

    var bpt_model = try BptModel.init(std.testing.allocator);
    defer bpt_model.deinit();
    var padding = Tree.init(&bpt_model, .force_split);
    var target = Tree.init(&bpt_model, .force_split);
    var source = Tree.init(&bpt_model, .force_split);
    var garbage = Tree.init(&bpt_model, .force_split);

    try std.testing.expect(try padding.insert(1, "unreachable"));
    try bpt_model.accessor().setRoot(null);
    try std.testing.expect(try target.insert(10, "target"));
    const target_root = bpt_model.accessor().getRoot().?;
    try bpt_model.accessor().setRoot(null);

    var encoded_target: [@sizeOf(usize)]u8 = undefined;
    std.mem.writeInt(usize, &encoded_target, target_root, .little);
    try std.testing.expect(try source.insert(20, &encoded_target));
    const source_root = bpt_model.accessor().getRoot().?;
    try bpt_model.accessor().setRoot(null);

    try std.testing.expect(try garbage.insert(30, "garbage"));
    const garbage_root = bpt_model.accessor().getRoot().?;

    var target_pages = [_]bool{false} ** 64;
    var source_pages = [_]bool{false} ** 64;
    var garbage_pages = [_]bool{false} ** 64;
    try collectBptGraph(BptModel, &bpt_model, target_root, &target_pages);
    try collectBptGraph(BptModel, &bpt_model, source_root, &source_pages);
    try collectBptGraph(BptModel, &bpt_model, garbage_root, &garbage_pages);
    const page_count = @max(
        @max(lastSet(&target_pages), lastSet(&source_pages)),
        lastSet(&garbage_pages),
    ) + 1;

    var free = [_]bool{false} ** 64;
    var store = MemoryStore(BptModel){
        .model = &bpt_model,
        .page_count = page_count,
        .free = &free,
    };
    const GcModel = fullaz.gc.models.Memory(@TypeOf(store));
    const Collector = fullaz.gc.Gc(GcModel);
    const Context = struct {
        model: *BptModel,
        target_root: usize,
    };
    const Scanners = struct {
        fn leaf(
            context: ?*const anyopaque,
            page_id: usize,
            page: []const u8,
            sink: Collector.ReferenceSink,
        ) Collector.Error!void {
            const ctx: *Context = @ptrCast(@alignCast(@constCast(context.?)));
            ctx.model.scanLeafRefs(page_id, page, sink) catch return error.InvalidPageId;
        }

        fn inode(
            context: ?*const anyopaque,
            page_id: usize,
            page: []const u8,
            sink: Collector.ReferenceSink,
        ) Collector.Error!void {
            const ctx: *Context = @ptrCast(@alignCast(@constCast(context.?)));
            ctx.model.scanInodeRefs(page_id, page, sink) catch return error.InvalidPageId;
        }

        fn scan(
            context: ?*const anyopaque,
            value: []const u8,
            sink: Collector.ReferenceSink,
        ) Collector.Error!void {
            _ = value;
            const ctx: *const Context = @ptrCast(@alignCast(context.?));
            try sink.visit(ctx.target_root);
        }
    };
    var context = Context{ .model = &bpt_model, .target_root = target_root };
    var gc_model = GcModel.init(std.testing.allocator, &store);
    defer gc_model.deinit();
    var collector = Collector.init(&gc_model);
    defer collector.deinit();
    try collector.register(1, 1, &context, Scanners.leaf, Scanners.scan);
    try collector.register(2, 1, &context, Scanners.inode, null);
    try collector.start(&.{source_root});
    while (gc_model.phase() != .sweeping) {
        _ = try collector.step(1);
    }
    try std.testing.expect(gc_model.isMarked(target_root));
    while (try collector.step(1) != .complete) {}

    for (target_pages, 0..) |was_in_graph, page_id| {
        if (was_in_graph) {
            try std.testing.expect(!free[page_id]);
        }
    }
    for (source_pages, 0..) |was_in_graph, page_id| {
        if (was_in_graph) {
            try std.testing.expect(!free[page_id]);
        }
    }
    for (garbage_pages, 0..) |was_in_graph, page_id| {
        if (was_in_graph) {
            try std.testing.expect(free[page_id]);
        }
    }
}

fn lastSet(bits: []const bool) usize {
    var index = bits.len;
    while (index > 0) {
        index -= 1;
        if (bits[index]) {
            return index;
        }
    }
    unreachable;
}

const PagedStore = struct {
    const page_size = 128;
    const Entry = struct {
        bytes: [page_size]u8 = [_]u8{0} ** page_size,
        free: bool = false,
    };

    entries: [256]Entry = [_]Entry{.{}} ** 256,
    count: usize = 0,
};

const PagedCache = struct {
    pub const Pid = u32;
    pub const Error = error{ InvalidPageId, OutOfPages };
    pub const UnderlyingDevice = struct {
        pub const BlockId = Pid;
    };
    pub const Handle = struct {
        pub const Error = PagedCache.Error;
        pub const Pid = PagedCache.Pid;
        pub const LayoutLock = struct {};

        store: *PagedStore,
        page_id: PagedCache.Pid,

        pub fn deinit(_: *@This()) void {}

        pub fn clone(self: *const @This()) PagedCache.Error!@This() {
            return self.*;
        }

        pub fn pid(self: *const @This()) PagedCache.Error!PagedCache.Pid {
            return self.page_id;
        }

        pub fn data(self: *const @This()) PagedCache.Error![]const u8 {
            return &self.store.entries[self.page_id].bytes;
        }

        pub fn dataMut(self: *@This()) PagedCache.Error![]u8 {
            return &self.store.entries[self.page_id].bytes;
        }

        pub fn markDirty(_: *@This()) PagedCache.Error!void {}

        pub fn isLayoutLocked(_: *const @This()) PagedCache.Error!bool {
            return false;
        }

        pub fn lockLayout(_: *const @This()) PagedCache.Error!LayoutLock {
            return .{};
        }

        pub fn take(self: *@This()) PagedCache.Error!@This() {
            const result = self.*;
            self.* = undefined;
            return result;
        }
    };

    store: *PagedStore,
    active: bool = true,

    pub fn transactionActive(self: *const @This()) bool {
        return self.active;
    }

    pub fn pageCount(self: *const @This()) usize {
        return self.store.count;
    }

    pub fn pageSize(_: *const @This()) usize {
        return PagedStore.page_size;
    }

    pub fn fetch(self: *@This(), page_id: Pid) Error!Handle {
        if (page_id >= self.store.count or self.store.entries[page_id].free) {
            return error.InvalidPageId;
        }
        return .{ .store = self.store, .page_id = page_id };
    }

    pub fn create(self: *@This()) Error!Handle {
        if (self.store.count == self.store.entries.len) {
            return error.OutOfPages;
        }
        const page_id: Pid = @intCast(self.store.count);
        self.store.count += 1;
        self.store.entries[page_id] = .{};
        return .{ .store = self.store, .page_id = page_id };
    }

    pub fn getTemporaryPage(self: *@This()) Error!Handle {
        return self.create();
    }

    pub fn flush(_: *@This(), _: Pid) Error!void {}

    pub fn flushAll(_: *@This()) Error!void {}
};

const PagedManager = struct {
    pub const PageId = u32;
    pub const Error = PagedCache.Error;

    store: *PagedStore,
    root: ?PageId = null,

    pub fn getRoot(self: *const @This()) ?PageId {
        return self.root;
    }

    pub fn setRoot(self: *@This(), page_id: ?PageId) Error!void {
        self.root = page_id;
    }

    pub fn isReserved(_: *const @This(), _: PageId) bool {
        return false;
    }

    pub fn isFree(self: *const @This(), page_id: PageId) Error!bool {
        if (page_id >= self.store.count) {
            return error.InvalidPageId;
        }
        return self.store.entries[page_id].free;
    }

    pub fn destroyPage(self: *@This(), page_id: PageId) Error!void {
        if (page_id >= self.store.count) {
            return error.InvalidPageId;
        }
        self.store.entries[page_id].free = true;
    }
};

fn pageKeyCmp(_: void, left: []const u8, right: []const u8) algos.Order {
    return algos.cmpSlices(u8, left, right, algos.CmpNum(u8).asc, {}) catch unreachable;
}

test "GC: paged model resumes while reclaiming one BPT graph" {
    const Settings = bpt.models.paged.Settings;
    const BptModel = bpt.models.PagedModel(PagedCache, PagedManager, pageKeyCmp, void);
    const Tree = bpt.Bpt(BptModel);
    const settings = Settings{
        .maximum_key_size = 8,
        .maximum_value_size = 8,
        .leaf_page_kind = 101,
        .inode_page_kind = 102,
    };

    var store = PagedStore{};
    var cache = PagedCache{ .store = &store };
    var dropped_manager = PagedManager{ .store = &store };
    var retained_manager = PagedManager{ .store = &store };
    var gc_manager = PagedManager{ .store = &store };
    var dropped_model = try BptModel.init(&cache, &dropped_manager, settings, {});
    var retained_model = try BptModel.init(&cache, &retained_manager, settings, {});
    var dropped_tree = Tree.init(&dropped_model, .force_split);
    var retained_tree = Tree.init(&retained_model, .force_split);

    for (0..12) |index| {
        var key: [8]u8 = undefined;
        const text = try std.fmt.bufPrint(&key, "d{d:0>2}", .{index});
        try std.testing.expect(try dropped_tree.insert(text, "dropped"));
    }
    for (0..12) |index| {
        var key: [8]u8 = undefined;
        const text = try std.fmt.bufPrint(&key, "r{d:0>2}", .{index});
        try std.testing.expect(try retained_tree.insert(text, "retained"));
    }
    const dropped_root = dropped_manager.root.?;
    const retained_root = retained_manager.root.?;
    var dropped_pages = [_]bool{false} ** 256;
    var retained_pages = [_]bool{false} ** 256;
    try collectBptGraph(BptModel, &dropped_model, dropped_root, &dropped_pages);
    try collectBptGraph(BptModel, &retained_model, retained_root, &retained_pages);

    {
        const GcModel = fullaz.gc.models.Paged(PagedCache, PagedManager);
        const Collector = fullaz.gc.Gc(GcModel);
        const Scanners = bptScanners(BptModel, Collector);
        var gc_model = try GcModel.init(std.testing.allocator, &cache, &gc_manager);
        defer gc_model.deinit();
        var collector = Collector.init(&gc_model);
        defer collector.deinit();
        try collector.register(settings.leaf_page_kind, 1, &retained_model, Scanners.leaf, null);
        try collector.register(settings.inode_page_kind, 1, &retained_model, Scanners.inode, null);
        try collector.start(&.{retained_root});
        while (gc_model.phase() != .marking) {
            _ = try collector.step(1);
        }
        _ = try collector.step(1);
        try std.testing.expect(gc_model.isCycleActive());
    }

    // Recreate the cache/model/collector objects while preserving their shared
    // page store and durable roots, then resume the active GC cycle.
    var reopened_cache = PagedCache{ .store = &store };
    var reopened_retained_manager = PagedManager{ .store = &store, .root = retained_root };
    var reopened_gc_manager = PagedManager{ .store = &store, .root = gc_manager.root };
    var reopened_retained_model = try BptModel.init(
        &reopened_cache,
        &reopened_retained_manager,
        settings,
        {},
    );
    const GcModel = fullaz.gc.models.Paged(PagedCache, PagedManager);
    const Collector = fullaz.gc.Gc(GcModel);
    const Scanners = bptScanners(BptModel, Collector);
    var reopened_gc_model = try GcModel.init(std.testing.allocator, &reopened_cache, &reopened_gc_manager);
    defer reopened_gc_model.deinit();
    var reopened = Collector.init(&reopened_gc_model);
    defer reopened.deinit();
    try reopened.registerResumed(settings.leaf_page_kind, 1, &reopened_retained_model, Scanners.leaf, null);
    try reopened.registerResumed(settings.inode_page_kind, 1, &reopened_retained_model, Scanners.inode, null);
    while (try reopened.step(1) != .complete) {}

    for (dropped_pages, 0..) |was_in_graph, page_id| {
        if (was_in_graph) {
            try std.testing.expect(store.entries[page_id].free);
        }
    }
    for (retained_pages, 0..) |was_in_graph, page_id| {
        if (was_in_graph) {
            try std.testing.expect(!store.entries[page_id].free);
        }
    }
    var reopened_tree = Tree.init(&reopened_retained_model, .force_split);
    const found = (try reopened_tree.find("r05")).?;
    defer found.deinit();
    try std.testing.expectEqualStrings("retained", (try found.get()).?.value);
}
