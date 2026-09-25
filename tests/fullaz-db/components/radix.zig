const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

fn TestBackend(comptime CacheT: type) type {
    return struct {
        const Self = @This();

        pub const PageId = CacheT.Pid;
        pub const CacheType = CacheT;

        allocator_value: std.mem.Allocator,
        cache_ptr: *CacheT,

        pub fn allocator(self: *const Self) std.mem.Allocator {
            return self.allocator_value;
        }

        pub fn cache(self: *Self) *CacheType {
            return self.cache_ptr;
        }
    };
}

test "fullaz-db: radix descriptor preserves validated options" {
    const Trait = fullaz_db.radix(.{
        .Key = u64,
        .value_size = 24,
        .format_version = 3,
    }).Trait;

    try std.testing.expectEqualStrings("fullaz.radix.paged", Trait.kind_name);
    try std.testing.expectEqual(@as(u32, 3), Trait.format_version);
    try std.testing.expectEqual(@as(usize, 2), Trait.page_kind_count);
    try std.testing.expectEqualSlices([]const u8, &.{ "leaf", "inode" }, &Trait.page_roles);
    try std.testing.expect(Trait.Key == u64);
    try std.testing.expectEqual(@as(usize, 24), Trait.value_size);
}

test "fullaz-db: radix binding supports point entries editors and fixed values" {
    const Device = fullaz.device.MemoryBlock(u32);
    const InnerCache = fullaz.storage.page_cache.PageCache(Device);
    const Cache = fullaz_db.MemoryReclaimingCache(InnerCache);
    const Backend = TestBackend(Cache);
    const Binding = fullaz_db.radix(.{
        .Key = u32,
        .value_size = 8,
    }).Trait.Binding(Backend);

    var device = try Device.init(std.testing.allocator, 4096);
    defer device.deinit();
    var inner = try InnerCache.init(&device, std.testing.allocator, 8);
    defer inner.deinit();
    var cache = Cache.init(std.testing.allocator, &inner);
    defer cache.deinit();
    var backend = Backend{
        .allocator_value = std.testing.allocator,
        .cache_ptr = &cache,
    };
    var runtime: Binding.Runtime = undefined;

    try std.testing.expectError(
        error.InvalidPageKinds,
        Binding.initRuntime(
            &runtime,
            &backend,
            .{ .base = 0x0100, .count = 1 },
            .{},
        ),
    );
    try Binding.initRuntime(
        &runtime,
        &backend,
        .{ .base = 0x0100, .count = 2 },
        .{},
    );
    defer Binding.deinitRuntime(&runtime);

    try std.testing.expect(runtime.state.root.isMax());
    try std.testing.expect(runtime.state.free_leaf_root.isMax());

    var transaction = try cache.begin();
    errdefer transaction.discard() catch {};
    const radix = Binding.proxy(&runtime);
    try std.testing.expect((try radix.find(7)) == null);
    try std.testing.expectError(error.BadLength, radix.set(7, "short"));
    try radix.set(7, "original");

    var entry = (try radix.find(7)).?;
    const original = try entry.get();
    try std.testing.expectEqual(@as(u32, 7), original.key);
    try std.testing.expectEqualSlices(u8, "original", original.value);

    var first_editor = try entry.editValue();
    @memcpy(try first_editor.valueMut(), "changed!");
    try first_editor.finish();

    var second_editor = (try radix.openValueEditor(7)).?;
    first_editor.deinit();
    try std.testing.expectError(error.ValueEditorActive, Binding.requireTransactionIdle(&runtime));
    second_editor.deinit();
    try Binding.requireTransactionIdle(&runtime);

    try std.testing.expectEqualSlices(u8, "changed!", (try entry.get()).value);
    entry.deinit();
    try transaction.commit();

    const radix_const = Binding.proxyConst(&runtime);
    var committed = (try radix_const.find(7)).?;
    defer committed.deinit();
    try std.testing.expectEqualSlices(u8, "changed!", (try committed.get()).value);
}

test "fullaz-db: radix metadata validates both persistent roots" {
    const Device = fullaz.device.MemoryBlock(u32);
    const InnerCache = fullaz.storage.page_cache.PageCache(Device);
    const Cache = fullaz_db.MemoryReclaimingCache(InnerCache);
    const Backend = TestBackend(Cache);
    const Binding = fullaz_db.radix(.{
        .Key = u32,
        .value_size = 8,
    }).Trait.Binding(Backend);

    var state: Binding.State = .{};
    try Binding.StaticMetadata.validate(&state, 0);

    state.free_leaf_root.set(1);
    try std.testing.expectError(
        error.BadMetadata,
        Binding.StaticMetadata.validate(&state, 2),
    );

    state.root.set(1);
    try Binding.StaticMetadata.validate(&state, 2);
    state.free_leaf_root.set(2);
    try std.testing.expectError(
        error.BadMetadata,
        Binding.StaticMetadata.validate(&state, 2),
    );

    state.root.set(0);
    state.free_leaf_root.set(0);
    try std.testing.expectError(
        error.BadMetadata,
        Binding.StaticMetadata.validate(&state, 2),
    );

    var payload_bytes: [64]u8 = undefined;
    var writer = fullaz_db.file.tagged_fields.Writer.init(&payload_bytes);
    try writer.append(0x0100, 0, std.mem.asBytes(&state));
    var runtime: Binding.Runtime = undefined;
    try std.testing.expectError(
        error.BadMetadata,
        Binding.DynamicMetadata.restore(&runtime, writer.used(), 2),
    );
}

test "fullaz-db: radix entry allocation failure releases its page pin" {
    const Device = fullaz.device.MemoryBlock(u32);
    const InnerCache = fullaz.storage.page_cache.PageCache(Device);
    const Cache = fullaz_db.MemoryReclaimingCache(InnerCache);
    const Backend = TestBackend(Cache);
    const Binding = fullaz_db.radix(.{
        .Key = u32,
        .value_size = 8,
    }).Trait.Binding(Backend);

    var device = try Device.init(std.testing.allocator, 4096);
    defer device.deinit();
    var inner = try InnerCache.init(&device, std.testing.allocator, 4);
    defer inner.deinit();
    var cache = Cache.init(std.testing.allocator, &inner);
    defer cache.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var backend = Backend{
        .allocator_value = failing.allocator(),
        .cache_ptr = &cache,
    };
    var runtime: Binding.Runtime = undefined;
    try Binding.initRuntime(
        &runtime,
        &backend,
        .{ .base = 0x0100, .count = 2 },
        .{},
    );
    defer Binding.deinitRuntime(&runtime);

    var transaction = try cache.begin();
    try Binding.proxy(&runtime).set(1, "value001");
    try transaction.commit();
    const root = runtime.state.root.get();

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(
        error.OutOfMemory,
        Binding.proxyConst(&runtime).find(1),
    );
    try std.testing.expect(!try cache.isPinned(root));
}

test "fullaz-db: radix participates in memory database commit and rollback" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 })
        .add("first", fullaz_db.radix(.{ .Key = u32, .value_size = 8 }))
        .add("second", fullaz_db.radix(.{ .Key = u64, .value_size = 8 }));
    const Database = fullaz_db.MemoryDatabase(Schema);
    var database = try Database.init(std.testing.allocator, .{
        .page_size = 512,
        .cache_frames = 8,
        .components = .{ .first = .{}, .second = .{} },
    });
    defer database.deinit();

    {
        var transaction = try database.begin();
        defer transaction.deinit();
        try transaction.get("first").set(7, "first001");
        try transaction.get("second").set(9, "second01");
        try transaction.commit();
    }
    {
        var first = (try database.getConst("first").find(7)).?;
        defer first.deinit();
        var second = (try database.getConst("second").find(9)).?;
        defer second.deinit();
        try std.testing.expectEqualSlices(u8, "first001", (try first.get()).value);
        try std.testing.expectEqualSlices(u8, "second01", (try second.get()).value);
    }
    {
        var transaction = try database.begin();
        defer transaction.deinit();
        try transaction.get("first").set(7, "changed!");
        try transaction.get("second").free(9);
        try transaction.rollback();
    }
    {
        var first = (try database.getConst("first").find(7)).?;
        defer first.deinit();
        var second = (try database.getConst("second").find(9)).?;
        defer second.deinit();
        try std.testing.expectEqualSlices(u8, "first001", (try first.get()).value);
        try std.testing.expectEqualSlices(u8, "second01", (try second.get()).value);
    }
    var reused_key: u32 = undefined;
    {
        var transaction = try database.begin();
        defer transaction.deinit();
        reused_key = (try transaction.get("first").takeFree("reused!!")).?;
        try transaction.commit();
    }
    var reused = (try database.getConst("first").find(reused_key)).?;
    defer reused.deinit();
    try std.testing.expectEqualSlices(u8, "reused!!", (try reused.get()).value);
}

test "fullaz-db: radix rejects stale transactions and poisons failed mutations" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add(
        "index",
        fullaz_db.radix(.{ .Key = u32, .value_size = 8 }),
    );
    const Database = fullaz_db.MemoryDatabase(Schema);
    var database = try Database.init(std.testing.allocator, .{
        .page_size = 512,
        .cache_frames = 8,
        .components = .{ .index = .{} },
    });
    defer database.deinit();

    var first_transaction = try database.begin();
    defer first_transaction.deinit();
    const stale = first_transaction.get("index");
    try stale.set(1, "value001");
    try first_transaction.commit();
    try std.testing.expectError(error.TransactionInactive, stale.set(2, "value002"));

    var second_transaction = try database.begin();
    defer second_transaction.deinit();
    const index = second_transaction.get("index");
    var entry = (try index.find(1)).?;
    try std.testing.expectError(error.ReadHandleActive, index.free(1));
    entry.deinit();
    try std.testing.expectError(error.TransactionRollbackOnly, second_transaction.commit());
    try second_transaction.rollback();

    var committed = (try database.getConst("index").find(1)).?;
    defer committed.deinit();
    try std.testing.expectEqualSlices(u8, "value001", (try committed.get()).value);
}
