const std = @import("std");
const fullaz = @import("fullaz");

const Store = struct {
    const page_size = 128;
    const Entry = struct {
        bytes: [page_size]u8 = [_]u8{0} ** page_size,
        free: bool = false,
        reserved: bool = false,
    };

    allocator: std.mem.Allocator,
    entries: []Entry,
    count: usize,
    gc_root: ?usize = null,

    fn init(allocator: std.mem.Allocator, page_count: usize) !Store {
        const entries = try allocator.alloc(Entry, page_count + 32);
        @memset(entries, Entry{});
        return .{ .allocator = allocator, .entries = entries, .count = page_count };
    }

    fn deinit(self: *Store) void {
        self.allocator.free(self.entries);
    }
};

const Cache = struct {
    pub const PageId = usize;
    pub const Error = error{ InvalidPageId, OutOfPages };
    pub const Pid = PageId;
    pub const UnderlyingDevice = struct {
        pub const BlockId = PageId;
    };
    pub const Handle = struct {
        pub const Error = Cache.Error;

        store: *Store,
        page_id: PageId,

        pub fn deinit(_: *@This()) void {}

        pub fn clone(self: *const @This()) Cache.Error!@This() {
            return self.*;
        }

        pub fn pid(self: *const @This()) Cache.Error!PageId {
            return self.page_id;
        }

        pub fn data(self: *const @This()) Cache.Error![]const u8 {
            return &self.store.entries[self.page_id].bytes;
        }

        pub fn dataMut(self: *@This()) Cache.Error![]u8 {
            return &self.store.entries[self.page_id].bytes;
        }
    };

    store: *Store,
    active: bool = false,

    pub fn transactionActive(self: *const @This()) bool {
        return self.active;
    }

    pub fn pageCount(self: *const @This()) usize {
        return self.store.count;
    }

    pub fn fetch(self: *@This(), page_id: PageId) Error!Handle {
        if (page_id >= self.store.count or self.store.entries[page_id].free) {
            return error.InvalidPageId;
        }
        return .{ .store = self.store, .page_id = page_id };
    }

    pub fn create(self: *@This()) Error!Handle {
        if (self.store.count == self.store.entries.len) {
            return error.OutOfPages;
        }
        const page_id = self.store.count;
        self.store.count += 1;
        self.store.entries[page_id] = .{};
        return .{ .store = self.store, .page_id = page_id };
    }

    pub fn pageSize(_: *const @This()) usize {
        return Store.page_size;
    }

    pub fn getTemporaryPage(_: *@This()) Error!Handle {
        return error.OutOfPages;
    }
};

const StorageManager = struct {
    pub const PageId = usize;
    pub const Error = Cache.Error;

    store: *Store,

    pub fn getRoot(self: *const @This()) ?PageId {
        return self.store.gc_root;
    }

    pub fn setRoot(self: *@This(), page_id: ?PageId) Error!void {
        self.store.gc_root = page_id;
    }

    pub fn isReserved(self: *const @This(), page_id: PageId) bool {
        return page_id < self.store.count and self.store.entries[page_id].reserved;
    }

    pub fn isFree(self: *const @This(), page_id: PageId) Error!bool {
        if (page_id >= self.store.count) {
            return error.InvalidPageId;
        }
        return self.store.entries[page_id].free;
    }

    pub fn destroyPage(self: *@This(), page_id: PageId) Error!void {
        if (page_id >= self.store.count or self.store.entries[page_id].reserved) {
            return error.InvalidPageId;
        }
        self.store.entries[page_id].free = true;
    }
};

test "GC: paged model persists unbounded chains and resumes after reopen" {
    const Model = fullaz.gc.models.Paged(Cache, StorageManager);
    const Collector = fullaz.gc.Gc(Model);
    const ScannerFixture = struct {
        fn branch(_: ?*const anyopaque, _: usize, page: []const u8, sink: Collector.ReferenceSink) Collector.Error!void {
            for (page[32..52]) |child| {
                try sink.visit(child);
            }
        }

        fn leaf(_: ?*const anyopaque, _: usize, _: []const u8, _: Collector.ReferenceSink) Collector.Error!void {}
    };

    var store = try Store.init(std.testing.allocator, 1_000);
    defer store.deinit();
    store.entries[0].reserved = true;
    std.mem.writeInt(u16, store.entries[1].bytes[0..2], 1, .little);
    for (0..20) |index| {
        std.mem.writeInt(u16, store.entries[index + 2].bytes[0..2], 2, .little);
        store.entries[1].bytes[32 + index] = @intCast(index + 2);
    }
    std.mem.writeInt(u16, store.entries[900].bytes[0..2], 2, .little);
    store.entries[999].free = true;
    {
        var cache = Cache{ .store = &store, .active = true };
        var manager = StorageManager{ .store = &store };
        var model = try Model.init(std.testing.allocator, &cache, &manager);
        var collector = Collector.init(&model);
        defer collector.deinit();
        try collector.register(1, 1, null, ScannerFixture.branch, null);
        try collector.register(2, 1, null, ScannerFixture.leaf, null);
        try collector.start(&.{1});
        while (model.phase() != .marking) {
            _ = try collector.step(200);
        }
        try std.testing.expect(try model.mark(900)); // Forces the mark bitmap onto its second page.
        try model.enqueue(900);
        _ = try collector.step(1);
        try std.testing.expect(store.count > 1_005); // state, two mark/free bitmap pages, and queue overflow
        try std.testing.expect(model.isCycleActive());
    }

    {
        var cache = Cache{ .store = &store, .active = true };
        var manager = StorageManager{ .store = &store };
        var reopened_model = try Model.init(std.testing.allocator, &cache, &manager);
        var reopened = Collector.init(&reopened_model);
        defer reopened.deinit();
        try reopened.registerResumed(1, 1, null, ScannerFixture.branch, null);
        try reopened.registerResumed(2, 1, null, ScannerFixture.leaf, null);
        while (try reopened.step(200) != .complete) {}
    }

    try std.testing.expect(!store.entries[1].free);
    try std.testing.expect(!store.entries[2].free);
    try std.testing.expect(!store.entries[900].free);
    try std.testing.expect(store.entries[22].free);
    try std.testing.expect(store.entries[999].free);
}

test "GC: paged model requires an active transaction to open state" {
    const Model = fullaz.gc.models.Paged(Cache, StorageManager);
    var store = try Store.init(std.testing.allocator, 1);
    defer store.deinit();
    var cache = Cache{ .store = &store };
    var manager = StorageManager{ .store = &store };

    try std.testing.expectError(error.TransactionInactive, Model.init(std.testing.allocator, &cache, &manager));
}
