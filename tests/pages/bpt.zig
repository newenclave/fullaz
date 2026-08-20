const std = @import("std");
const fullaz = @import("fullaz");

fn compare(_: void, left: []const u8, right: []const u8) fullaz.core.algorithm.Order {
    return switch (std.mem.order(u8, left, right)) {
        .lt => .lt,
        .eq => .eq,
        .gt => .gt,
    };
}

const CompareContext = struct {
    descending: bool,
};

fn compareWithContext(
    context: CompareContext,
    left: []const u8,
    right: []const u8,
) fullaz.core.algorithm.Order {
    const ascending = compare({}, left, right);
    if (!context.descending) {
        return ascending;
    }
    return switch (ascending) {
        .lt => .gt,
        .eq => .eq,
        .gt => .lt,
        .unordered => .unordered,
    };
}

fn TestBackend(comptime CacheT: type) type {
    return struct {
        const Self = @This();

        pub const PageId = CacheT.Pid;
        pub const CacheType = CacheT;

        cache_ptr: *CacheT,

        pub fn cache(self: *Self) *CacheType {
            return self.cache_ptr;
        }
    };
}

test "Pages: paged BPT descriptor preserves validated options" {
    const descriptor = fullaz.pages.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 7,
        .maximum_key_size = 64,
        .maximum_value_size = 256,
    });
    const Trait = descriptor.Trait;

    try std.testing.expectEqualStrings("fullaz.bpt.paged", Trait.kind_name);
    try std.testing.expectEqual(@as(u32, 1), Trait.format_version);
    try std.testing.expectEqual(@as(usize, 2), Trait.page_kind_count);
    try std.testing.expectEqualSlices([]const u8, &.{ "leaf", "inode" }, &Trait.page_roles);
    try std.testing.expectEqual(@as(u32, 7), Trait.comparator_id);
    try std.testing.expect(Trait.CompareContext == void);
    try std.testing.expect(@TypeOf(Trait.compare) == @TypeOf(compare));
    try std.testing.expectEqual(@as(usize, 64), Trait.maximum_key_size);
    try std.testing.expectEqual(@as(usize, 256), Trait.maximum_value_size);
    try std.testing.expectEqual(.neighbor_share, Trait.rebalance_policy);
}

test "Pages: paged BPT descriptor accepts explicit optional options" {
    const Trait = fullaz.pages.bpt(.{
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

test "Pages: paged BPT binding generates a reclaiming storage manager" {
    const Device = fullaz.device.MemoryBlock(u32);
    const InnerCache = fullaz.storage.page_cache.PageCache(Device);
    const Cache = fullaz.pages.MemoryReclaimingCache(InnerCache);
    const Backend = TestBackend(Cache);
    const Trait = fullaz.pages.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 64,
        .maximum_value_size = 128,
    }).Trait;
    const Manager = Trait.Binding(Backend).Manager;

    var device = try Device.init(std.testing.allocator, 4096);
    defer device.deinit();
    var inner = try InnerCache.init(&device, std.testing.allocator, 4);
    defer inner.deinit();
    var cache = Cache.init(std.testing.allocator, &inner);
    defer cache.deinit();
    var backend = Backend{ .cache_ptr = &cache };
    var manager = Manager.init(&backend);

    try std.testing.expectEqual(null, manager.getRoot());
    var handle = try cache.create();
    const page_id = try handle.pid();
    handle.deinit();
    try manager.setRoot(page_id);
    try std.testing.expectEqual(page_id, manager.getRoot().?);

    try manager.destroyPage(page_id);
    try std.testing.expectEqualSlices(u32, &.{page_id}, cache.free_pages.items);
}

test "Pages: paged BPT binding initializes a typed runtime in place" {
    const Device = fullaz.device.MemoryBlock(u32);
    const InnerCache = fullaz.storage.page_cache.PageCache(Device);
    const Cache = fullaz.pages.MemoryReclaimingCache(InnerCache);
    const Backend = TestBackend(Cache);
    const Trait = fullaz.pages.bpt(.{
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
    var backend = Backend{ .cache_ptr = &cache };
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

    const tree = Binding.proxy(&runtime);
    try std.testing.expect(tree == &runtime.tree);
    try std.testing.expect(tree.model == &runtime.model);
    try std.testing.expect(try tree.insert("hello", "world"));
    var found = (try tree.find("hello")).?;
    defer found.deinit();
    const entry = (try found.get()).?;
    try std.testing.expectEqualStrings("world", entry.value);

    const runtime_const: *const Binding.Runtime = &runtime;
    try std.testing.expect(Binding.proxyConst(runtime_const) == &runtime.tree);
}

test "Pages: paged BPT binding requires and copies non-void compare context" {
    const Device = fullaz.device.MemoryBlock(u32);
    const InnerCache = fullaz.storage.page_cache.PageCache(Device);
    const Cache = fullaz.pages.MemoryReclaimingCache(InnerCache);
    const Backend = TestBackend(Cache);
    const Trait = fullaz.pages.bpt(.{
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
    var backend = Backend{ .cache_ptr = &cache };
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

    const tree = Binding.proxy(&runtime);
    try std.testing.expect(try tree.insert("alpha", "first"));
    try std.testing.expect(try tree.insert("beta", "second"));
    var iterator = (try tree.iterator()).?;
    defer iterator.deinit();
    const first = (try iterator.next()).?;
    try std.testing.expectEqualStrings("beta", first.key);
}
