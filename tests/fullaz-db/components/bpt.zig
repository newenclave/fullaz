const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

fn compare(_: void, left: []const u8, right: []const u8) std.math.Order {
    return std.mem.order(u8, left, right);
}

const CompareContext = struct {
    descending: bool,
};

fn compareWithContext(
    context: CompareContext,
    left: []const u8,
    right: []const u8,
) std.math.Order {
    const ascending = compare({}, left, right);
    if (!context.descending) {
        return ascending;
    }
    return ascending.invert();
}

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

test "fullaz-db: paged BPT descriptor preserves validated options" {
    const descriptor = fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 7,
        .maximum_key_size = 64,
        .maximum_value_size = 256,
    });
    const Trait = descriptor.Trait;

    try std.testing.expectEqualStrings("fullaz.bpt.paged", Trait.kind_name);
    try std.testing.expectEqual(@as(u32, 2), Trait.format_version);
    try std.testing.expectEqual(@as(usize, 2), Trait.page_kind_count);
    try std.testing.expectEqualSlices([]const u8, &.{ "leaf", "inode" }, &Trait.page_roles);
    try std.testing.expectEqual(@as(u32, 7), Trait.comparator_id);
    try std.testing.expect(Trait.CompareContext == void);
    try std.testing.expect(@TypeOf(Trait.compare) == @TypeOf(compare));
    try std.testing.expectEqual(@as(usize, 64), Trait.maximum_key_size);
    try std.testing.expectEqual(@as(usize, 256), Trait.maximum_value_size);
    try std.testing.expectEqual(.neighbor_share, Trait.rebalance_policy);
}

test "fullaz-db: paged BPT descriptor accepts explicit optional options" {
    const Trait = fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 9,
        .maximum_key_size = 32,
        .maximum_value_size = 48,
        .rebalance_policy = .force_split,
        .format_version = 3,
    }).Trait;

    try std.testing.expectEqual(@as(u32, 3), Trait.format_version);
    try std.testing.expectEqual(.force_split, Trait.rebalance_policy);
}

test "fullaz-db: paged BPT binding generates a reclaiming storage manager" {
    const Device = fullaz.device.MemoryBlock(u32);
    const InnerCache = fullaz.storage.page_cache.PageCache(Device);
    const Cache = fullaz_db.MemoryReclaimingCache(InnerCache);
    const Backend = TestBackend(Cache);
    const Trait = fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 64,
        .maximum_value_size = 128,
    }).Trait;
    const Binding = Trait.Binding(Backend);
    const Manager = Binding.Manager;

    var device = try Device.init(std.testing.allocator, 4096);
    defer device.deinit();
    var inner = try InnerCache.init(&device, std.testing.allocator, 4);
    defer inner.deinit();
    var cache = Cache.init(std.testing.allocator, &inner);
    defer cache.deinit();
    var backend = Backend{
        .allocator_value = std.testing.allocator,
        .cache_ptr = &cache,
    };
    var state: Binding.State = .{};
    var manager = Manager.init(&backend, &state);

    try std.testing.expect(state.root.isMax());
    var handle = try cache.create();
    const page_id = try handle.pid();
    handle.deinit();
    state.root.set(page_id);
    var lease = try manager.state();
    defer lease.deinit();
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&state), try lease.data());

    try manager.destroyPage(page_id);
    try std.testing.expectEqualSlices(u32, &.{page_id}, cache.free_pages.items);
}

test "fullaz-db: paged BPT binding initializes a typed runtime in place" {
    const Device = fullaz.device.MemoryBlock(u32);
    const InnerCache = fullaz.storage.page_cache.PageCache(Device);
    const Cache = fullaz_db.MemoryReclaimingCache(InnerCache);
    const Backend = TestBackend(Cache);
    const Trait = fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 64,
        .maximum_value_size = 128,
    }).Trait;
    const Binding = Trait.Binding(Backend);

    var device = try Device.init(std.testing.allocator, 4096);
    defer device.deinit();
    var inner = try InnerCache.init(&device, std.testing.allocator, 4);
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

    var transaction = try cache.begin();
    errdefer transaction.discard() catch {};
    const tree = Binding.proxy(&runtime);
    try std.testing.expect(try tree.insert("hello", "world"));
    try transaction.commit();

    const runtime_const: *const Binding.Runtime = &runtime;
    const tree_const = Binding.proxyConst(runtime_const);
    try std.testing.expect(tree_const == &runtime.const_proxy);
    var found = (try tree_const.find("hello")).?;
    defer found.deinit();
    const entry = (try found.get()).?;
    try std.testing.expectEqualStrings("world", entry.value);
}

test "fullaz-db: paged BPT reclaims the first leaf after a failed insert" {
    const Device = fullaz.device.MemoryBlock(u32);
    const InnerCache = fullaz.storage.page_cache.PageCache(Device);
    const Cache = fullaz_db.MemoryReclaimingCache(InnerCache);
    const Backend = TestBackend(Cache);
    const Trait = fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 4,
        .maximum_value_size = 16,
    }).Trait;
    const Binding = Trait.Binding(Backend);

    var device = try Device.init(std.testing.allocator, 256);
    defer device.deinit();
    var inner = try InnerCache.init(&device, std.testing.allocator, 2);
    defer inner.deinit();
    var cache = Cache.init(std.testing.allocator, &inner);
    defer cache.deinit();
    var backend = Backend{
        .allocator_value = std.testing.allocator,
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

    try std.testing.expectError(error.KeyTooLarge, runtime.tree.insert("oversized", "value"));
    try std.testing.expect(runtime.state.root.isMax());
    try std.testing.expectEqualSlices(u32, &.{0}, cache.free_pages.items);

    try std.testing.expect(try runtime.tree.insert("key", "value"));
    try std.testing.expectEqual(@as(u32, 0), runtime.state.root.get());
    try std.testing.expectEqual(@as(usize, 0), cache.free_pages.items.len);
    try std.testing.expectEqual(@as(usize, 1), device.blocksCount());
}

test "fullaz-db: paged BPT binding requires and copies non-void compare context" {
    const Device = fullaz.device.MemoryBlock(u32);
    const InnerCache = fullaz.storage.page_cache.PageCache(Device);
    const Cache = fullaz_db.MemoryReclaimingCache(InnerCache);
    const Backend = TestBackend(Cache);
    const Trait = fullaz_db.bpt(.{
        .compare = compareWithContext,
        .CompareContext = CompareContext,
        .comparator_id = 2,
        .maximum_key_size = 64,
        .maximum_value_size = 128,
    }).Trait;
    const Binding = Trait.Binding(Backend);

    const option_fields = @typeInfo(Binding.InitOptions).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 1), option_fields.len);
    try std.testing.expect(option_fields[0].default_value_ptr == null);

    var device = try Device.init(std.testing.allocator, 4096);
    defer device.deinit();
    var inner = try InnerCache.init(&device, std.testing.allocator, 4);
    defer inner.deinit();
    var cache = Cache.init(std.testing.allocator, &inner);
    defer cache.deinit();
    var backend = Backend{
        .allocator_value = std.testing.allocator,
        .cache_ptr = &cache,
    };
    var runtime: Binding.Runtime = undefined;
    var context = CompareContext{ .descending = true };
    try Binding.initRuntime(
        &runtime,
        &backend,
        .{ .base = 0x0100, .count = 2 },
        .{ .compare_context = context },
    );
    defer Binding.deinitRuntime(&runtime);
    context.descending = false;

    var transaction = try cache.begin();
    errdefer transaction.discard() catch {};
    const tree = Binding.proxy(&runtime);
    try std.testing.expect(try tree.insert("alpha", "first"));
    try std.testing.expect(try tree.insert("beta", "second"));
    try transaction.commit();

    var iterator = (try Binding.proxyConst(&runtime).iterator()).?;
    defer iterator.deinit();
    const first = (try iterator.next()).?;
    try std.testing.expectEqualStrings("beta", first.key);
}
