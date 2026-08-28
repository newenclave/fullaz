const std = @import("std");
const fullaz = @import("fullaz");
const dev = fullaz.device;

fn TestTypes(comptime VirtualPageIdT: type) type {
    const Device = fullaz.device.MemoryBlock(u32);
    const InnerCache = fullaz.storage.page_cache.PageCache(Device);
    const Map = fullaz.storage.virtual_page_map.Memory(u32, VirtualPageIdT);
    const Cache = fullaz.storage.page_cache.VirtualPageCacheImpl(
        InnerCache,
        Map,
        fullaz.storage.page_cache.InPlaceWritePolicy,
    );

    comptime {
        if (@hasDecl(Cache, "UnderlyingDevice")) {
            @compileError("VirtualPageCache must not expose its underlying device");
        }
    }

    return struct {
        device: Device = undefined,
        inner: InnerCache = undefined,
        map: Map = undefined,
        cache: Cache = undefined,

        fn init(self: *@This()) !void {
            self.device = try Device.init(std.testing.allocator, 256);
            errdefer self.device.deinit();
            self.inner = try InnerCache.init(&self.device, std.testing.allocator, 4);
            errdefer self.inner.deinit();
            self.map = Map.init(std.testing.allocator);
            errdefer self.map.deinit();
            self.cache = Cache.init(&self.inner, &self.map, .init());
        }

        fn deinit(self: *@This()) void {
            self.map.deinit();
            self.inner.deinit();
            self.device.deinit();
        }
    };
}

fn PagedStateManager(comptime CacheT: type) type {
    return struct {
        const Self = @This();
        const ManagerError = CacheT.Error;

        pub const PageId = CacheT.Pid;
        pub const Error = ManagerError;
        pub const StateLeaseType = StateLease;

        pub const StateLease = struct {
            const LeaseError = CacheT.Handle.Error;

            pub const Error = LeaseError;

            handle: CacheT.Handle,
            manager: *Self,

            pub fn data(self: *const @This()) LeaseError![]const u8 {
                return self.handle.data();
            }

            pub fn dataMut(self: *@This()) LeaseError![]u8 {
                return self.handle.dataMut();
            }

            pub fn deinit(self: *@This()) void {
                self.handle.deinit();
                self.manager.active_state_leases -= 1;
            }
        };

        cache: *CacheT,
        state_page_id: PageId,
        active_state_leases: usize = 0,
        destroyed_pages: usize = 0,

        pub fn init(cache: *CacheT, state_page_id: PageId) Self {
            return .{
                .cache = cache,
                .state_page_id = state_page_id,
            };
        }

        pub fn state(self: *Self) ManagerError!StateLease {
            const handle = try self.cache.fetch(self.state_page_id);
            self.active_state_leases += 1;
            return .{
                .handle = handle,
                .manager = self,
            };
        }

        pub fn destroyPage(self: *Self, _: PageId) ManagerError!void {
            self.destroyed_pages += 1;
        }
    };
}

const WritePolicyCounts = struct {
    begins: usize = 0,
    commits: usize = 0,
    discards: usize = 0,
    prepare_creates: usize = 0,
    created: usize = 0,
    handle_writes: usize = 0,
    layout_writes: usize = 0,
};

fn RecordingWritePolicy(comptime ContextT: type) type {
    return struct {
        const Self = @This();

        pub const Error = error{};

        pub const WriteBatch = struct {
            counts: *WritePolicyCounts,

            pub fn commit(self: *@This()) void {
                self.counts.commits += 1;
            }

            pub fn discard(self: *@This()) void {
                self.counts.discards += 1;
            }
        };

        counts: *WritePolicyCounts,

        pub fn init(counts: *WritePolicyCounts) Self {
            return .{ .counts = counts };
        }

        pub fn deinit(_: *Self) void {}

        pub fn begin(
            self: *Self,
            _: ContextT.CacheRefs,
            _: u64,
        ) Error!WriteBatch {
            self.counts.begins += 1;
            return .{ .counts = self.counts };
        }

        pub fn prepareCreate(
            self: *Self,
            _: ContextT.CacheRefs,
        ) Error!void {
            self.counts.prepare_creates += 1;
        }

        pub fn created(
            self: *Self,
            _: ContextT.HandleTarget,
        ) void {
            self.counts.created += 1;
        }

        pub fn prepareHandleWrite(
            self: *Self,
            _: ContextT.HandleTarget,
        ) Error!void {
            self.counts.handle_writes += 1;
        }

        pub fn prepareLayoutWrite(
            self: *Self,
            _: ContextT.LayoutTarget,
        ) Error!void {
            self.counts.layout_writes += 1;
        }
    };
}

fn RejectingWritePolicy(comptime ContextT: type) type {
    return struct {
        const Self = @This();

        pub const Error = error{WriteRejected};

        pub const WriteBatch = struct {
            pub fn commit(_: *@This()) void {}

            pub fn discard(_: *@This()) void {}
        };

        pub fn init() Self {
            return .{};
        }

        pub fn deinit(_: *Self) void {}

        pub fn begin(
            _: *Self,
            _: ContextT.CacheRefs,
            _: u64,
        ) Error!WriteBatch {
            return .{};
        }

        pub fn prepareCreate(
            _: *Self,
            _: ContextT.CacheRefs,
        ) Error!void {
            return error.WriteRejected;
        }

        pub fn created(
            _: *Self,
            _: ContextT.HandleTarget,
        ) void {}

        pub fn prepareHandleWrite(
            _: *Self,
            _: ContextT.HandleTarget,
        ) Error!void {}

        pub fn prepareLayoutWrite(
            _: *Self,
            _: ContextT.LayoutTarget,
        ) Error!void {}
    };
}

test "VirtualPageCache exposes virtual page IDs only" {
    const Types = TestTypes(u16);

    var types: Types = undefined;
    try types.init();
    defer types.deinit();

    {
        var physical = try types.inner.create();
        physical.deinit();
    }

    var batch = try types.cache.begin();
    var page = try types.cache.create();
    const virtual_page_id = try page.pid();
    try std.testing.expectEqual(@as(u16, 0), virtual_page_id);
    try std.testing.expectEqual(@as(u32, 1), try types.map.get(virtual_page_id));
    try std.testing.expectEqual(@as(usize, 1), types.cache.pageCount());
    try std.testing.expectEqual(@as(usize, 2), types.inner.pageCount());
    (try page.dataMut())[0] = 0xaa;
    page.deinit();
    try batch.commit();

    var fetched = try types.cache.fetch(virtual_page_id);
    defer fetched.deinit();
    try std.testing.expectEqual(@as(u8, 0xaa), (try fetched.data())[0]);
    try types.cache.flush(virtual_page_id);
}

test "VirtualPageCache preserves virtual identity through handle ownership operations" {
    const Types = TestTypes(u32);

    var types: Types = undefined;
    try types.init();
    defer types.deinit();

    var batch = try types.cache.begin();
    var page = try types.cache.create();
    const virtual_page_id = try page.pid();

    var cloned = try page.clone();
    try std.testing.expectEqual(virtual_page_id, try cloned.pid());
    cloned.deinit();

    var lock = try page.lockLayout();
    try std.testing.expectEqual(virtual_page_id, try lock.pid());
    lock.deinit();

    var taken = try page.take();
    try std.testing.expectError(error.InvalidHandle, page.pid());
    try std.testing.expectEqual(virtual_page_id, try taken.pid());
    taken.deinit();

    var temporary = try types.cache.getTemporaryPage();
    try std.testing.expectError(error.InvalidId, temporary.pid());
    temporary.deinit();
    try batch.commit();
}

test "VirtualPageCache resolves fallible pinned state through the VPM" {
    const Types = TestTypes(u32);

    var types: Types = undefined;
    try types.init();
    defer types.deinit();

    var batch = try types.cache.begin();
    var page = try types.cache.create();
    const virtual_page_id = try page.pid();
    try std.testing.expect(try types.cache.isPinned(virtual_page_id));
    page.deinit();
    try std.testing.expect(!(try types.cache.isPinned(virtual_page_id)));
    try std.testing.expectError(error.VirtualPageNotMapped, types.cache.isPinned(1));
    try batch.commit();
}

test "VirtualPageCache delegates persistent writes to its policy" {
    const Device = fullaz.device.MemoryBlock(u32);
    const InnerCache = fullaz.storage.page_cache.PageCache(Device);
    const Map = fullaz.storage.virtual_page_map.Memory(u32, u32);
    const Cache = fullaz.storage.page_cache.VirtualPageCacheImpl(
        InnerCache,
        Map,
        RecordingWritePolicy,
    );

    var device = try Device.init(std.testing.allocator, 256);
    defer device.deinit();
    var inner = try InnerCache.init(&device, std.testing.allocator, 4);
    defer inner.deinit();
    var map = Map.init(std.testing.allocator);
    defer map.deinit();
    var counts = WritePolicyCounts{};
    var cache = Cache.init(&inner, &map, .init(&counts));
    defer cache.deinit();

    var batch = try cache.begin();
    try std.testing.expectEqual(@as(usize, 1), counts.begins);
    var page = try cache.create();
    const virtual_page_id = try page.pid();
    const physical_page_id = try map.get(virtual_page_id);
    try std.testing.expectEqual(@as(usize, 1), counts.prepare_creates);
    try std.testing.expectEqual(@as(usize, 1), counts.created);

    try page.markDirty();
    (try page.dataMut())[0] = 0x5a;
    var lock = try page.lockLayout();
    (try lock.dataMut())[1] = 0xa5;
    var temporary = try cache.getTemporaryPage();
    (try temporary.dataMut())[0] = 0xff;
    temporary.deinit();
    page.deinit();
    lock.deinit();

    try std.testing.expectEqual(@as(usize, 2), counts.handle_writes);
    try std.testing.expectEqual(@as(usize, 1), counts.layout_writes);
    try std.testing.expectEqual(physical_page_id, try map.get(virtual_page_id));
    try std.testing.expectEqual(@as(usize, 1), inner.pageCount());
    try batch.commit();
    try std.testing.expectEqual(@as(usize, 1), counts.commits);

    var fetched = try cache.fetch(virtual_page_id);
    defer fetched.deinit();
    try std.testing.expectEqual(@as(u8, 0x5a), (try fetched.data())[0]);
    try std.testing.expectEqual(@as(u8, 0xa5), (try fetched.data())[1]);
}

test "VirtualPageCache propagates policy errors before allocation" {
    const Device = fullaz.device.MemoryBlock(u32);
    const InnerCache = fullaz.storage.page_cache.PageCache(Device);
    const Map = fullaz.storage.virtual_page_map.Memory(u32, u32);
    const Cache = fullaz.storage.page_cache.VirtualPageCacheImpl(
        InnerCache,
        Map,
        RejectingWritePolicy,
    );

    var device = try Device.init(std.testing.allocator, 256);
    defer device.deinit();
    var inner = try InnerCache.init(&device, std.testing.allocator, 2);
    defer inner.deinit();
    var map = Map.init(std.testing.allocator);
    defer map.deinit();
    var cache = Cache.init(&inner, &map, .init());
    defer cache.deinit();

    var batch = try cache.begin();
    try std.testing.expectError(error.WriteRejected, cache.create());
    try std.testing.expectEqual(@as(usize, 0), inner.pageCount());
    try std.testing.expectEqual(@as(usize, 0), map.pageCount());
    try batch.discard();
}

test "VirtualPageCache commits and discards pages with their mappings" {
    const Types = TestTypes(u32);

    var types: Types = undefined;
    try types.init();
    defer types.deinit();

    {
        var batch = try types.cache.begin();
        var page = try types.cache.create();
        (try page.dataMut())[0] = 0x5a;
        page.deinit();
        try batch.discard();
    }
    try std.testing.expectEqual(@as(usize, 0), types.cache.pageCount());
    try std.testing.expectEqual(@as(usize, 0), types.inner.pageCount());

    var batch = try types.cache.begin();
    var page = try types.cache.create();
    const virtual_page_id = try page.pid();
    (try page.dataMut())[0] = 0x5a;
    page.deinit();
    try batch.commit();

    try std.testing.expectEqual(@as(usize, 1), types.cache.pageCount());
    var fetched = try types.cache.fetch(virtual_page_id);
    defer fetched.deinit();
    try std.testing.expectEqual(@as(u8, 0x5a), (try fetched.data())[0]);
}

test "VirtualPageCache reserves VPM capacity before allocating a physical page" {
    const Device = fullaz.device.MemoryBlock(u32);
    const InnerCache = fullaz.storage.page_cache.PageCache(Device);
    const Map = fullaz.storage.virtual_page_map.Memory(u32, u32);
    const Cache = fullaz.storage.page_cache.VirtualPageCacheImpl(
        InnerCache,
        Map,
        fullaz.storage.page_cache.InPlaceWritePolicy,
    );

    var device = try Device.init(std.testing.allocator, 256);
    defer device.deinit();
    var inner = try InnerCache.init(&device, std.testing.allocator, 2);
    defer inner.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var map = Map.init(failing.allocator());
    defer map.deinit();
    var cache = Cache.init(&inner, &map, .init());

    var batch = try cache.begin();
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, cache.create());
    try std.testing.expectEqual(@as(usize, 0), inner.pageCount());
    try batch.discard();
}

test "VirtualPageCache commits and discards a page-backed Paged VPM state lease" {
    const Device = fullaz.device.MemoryBlock(u32);
    const InnerCache = fullaz.storage.page_cache.PageCache(Device);
    const Manager = PagedStateManager(InnerCache);
    const Map = fullaz.storage.virtual_page_map.Paged(InnerCache, Manager, u32);
    const Cache = fullaz.storage.page_cache.VirtualPageCacheImpl(
        InnerCache,
        Map,
        fullaz.storage.page_cache.InPlaceWritePolicy,
    );
    const settings = Map.Settings{
        .virtual_to_physical = .{ .leaf = 1, .inode = 2 },
        .physical_to_virtual = .{ .leaf = 3, .inode = 4 },
    };

    var device = try Device.init(std.testing.allocator, 256);
    defer device.deinit();
    var inner = try InnerCache.init(&device, std.testing.allocator, 32);
    defer inner.deinit();

    var setup_batch = try inner.begin();
    var state_page = try inner.create();
    const state_page_id = try state_page.pid();
    state_page.deinit();
    var manager = Manager.init(&inner, state_page_id);
    var map = try Map.format(&inner, &manager, settings);
    defer map.deinit();
    try setup_batch.commit();

    var cache = Cache.init(&inner, &map, .init());
    defer cache.deinit();
    var batch = try cache.begin();
    try std.testing.expectEqual(@as(usize, 1), manager.active_state_leases);
    var page = try cache.create();
    const virtual_page_id = try page.pid();
    (try page.dataMut())[0] = 0x7a;
    page.deinit();
    try batch.commit();
    try std.testing.expectEqual(@as(usize, 0), manager.active_state_leases);

    var fetched = try cache.fetch(virtual_page_id);
    defer fetched.deinit();
    try std.testing.expectEqual(@as(u8, 0x7a), (try fetched.data())[0]);
    try std.testing.expectEqual(@as(usize, 0), manager.active_state_leases);

    const physical_page_count = inner.pageCount();
    var rollback_batch = try cache.begin();
    try std.testing.expectEqual(@as(usize, 1), manager.active_state_leases);
    var cancelled = try cache.create();
    cancelled.deinit();
    try rollback_batch.discard();
    try std.testing.expectEqual(@as(usize, 0), manager.active_state_leases);
    try std.testing.expectEqual(physical_page_count, inner.pageCount());
    try std.testing.expectEqual(@as(usize, 1), cache.pageCount());
    var retained = try cache.fetch(virtual_page_id);
    defer retained.deinit();
    try std.testing.expectEqual(@as(u8, 0x7a), (try retained.data())[0]);
}

const PageCacheT = @import("fullaz").storage.page_cache.PageCache;
const bpt = @import("fullaz").bpt;

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

const algorithm = @import("fullaz").core.algorithm;

fn keyCmp(ctx: anytype, k1: []const u8, k2: []const u8) algorithm.Order {
    return algorithm.cmpSlices(u8, k1, k2, algorithm.CmpNum(u8).asc, ctx) catch .gt;
}

test "VirtualPageCache BtpTree: Create and insert" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const Map = fullaz.storage.virtual_page_map.Memory(u32, u32);
    const Cache = fullaz.storage.page_cache.VirtualPageCacheImpl(
        PageCache,
        Map,
        fullaz.storage.page_cache.InPlaceWritePolicy,
    );

    const BptModel = bpt.models.PagedModel(Cache, NoneStorageManager, keyCmp, void);

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();

    var map = Map.init(allocator);
    defer map.deinit();

    var vcache = Cache.init(&cache, &map, .init());
    defer vcache.deinit();

    const available_before = cache.availableFrames();

    var store_mgr = NoneStorageManager{};
    var model = try BptModel.init(&vcache, &store_mgr, .{}, {});
    defer model.deinit();

    var tree = bpt.Bpt(BptModel).init(&model, .neighbor_share);
    // Create an inode

    var tx = try vcache.begin();
    errdefer tx.discard() catch {};

    _ = try tree.insert("x", "First Value");
    _ = try tree.insert("y", "Second Value");
    _ = try tree.insert("z", "Third Value");
    _ = try tree.update("x", "Updated First Value");

    try tx.commit();

    const val = try tree.find("x");
    try std.testing.expectEqualStrings("Updated First Value", (try val.?.get()).?.value);

    val.?.deinit();
    const available_after = cache.availableFrames();
    try std.testing.expectEqual(available_before, available_after);
}
