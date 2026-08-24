const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

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

const Collector = struct {
    count: usize = 0,
    sum: u32 = 0,

    fn callback(self: *Collector, _: anytype, value: []const u8) void {
        self.count += 1;
        self.sum += std.mem.readInt(u32, value[0..4], .little);
    }
};

const ValuesCollector = struct {
    seen: [16]bool = [_]bool{false} ** 16,

    fn callback(self: *ValuesCollector, _: anytype, value: []const u8) void {
        const index = std.mem.readInt(u32, value[0..4], .little);
        self.seen[index] = true;
    }
};

const FailingCollector = struct {
    fn callback(_: *FailingCollector, _: anytype, _: []const u8) error{Stopped}!void {
        return error.Stopped;
    }
};

const MatchesValue = struct {
    value: u32,

    fn callback(self: *const MatchesValue, _: anytype, value: []const u8) bool {
        return std.mem.readInt(u32, value[0..4], .little) == self.value;
    }
};

test "fullaz-db: paged R-tree descriptor preserves validated options" {
    const Trait = fullaz_db.rtree(.{
        .Coord = i64,
        .dimensions = 2,
        .maximum_entries = 4,
        .maximum_value_size = 16,
    }).Trait;

    try std.testing.expectEqualStrings("fullaz.rtree.paged", Trait.kind_name);
    try std.testing.expectEqual(@as(u32, 1), Trait.format_version);
    try std.testing.expectEqual(@as(usize, 2), Trait.page_kind_count);
    try std.testing.expectEqualSlices([]const u8, &.{ "leaf", "inode" }, &Trait.page_roles);
    try std.testing.expect(Trait.Coord == i64);
    try std.testing.expectEqual(@as(usize, 2), Trait.dimensions);
    try std.testing.expectEqual(@as(usize, 4), Trait.maximum_entries);
    try std.testing.expectEqual(@as(usize, 16), Trait.maximum_value_size);
}

test "fullaz-db: paged R-tree binding wires transaction and read facades" {
    const Device = fullaz.device.MemoryBlock(u32);
    const InnerCache = fullaz.storage.page_cache.PageCache(Device);
    const Cache = fullaz_db.MemoryReclaimingCache(InnerCache);
    const Backend = TestBackend(Cache);
    const Trait = fullaz_db.rtree(.{
        .Coord = i64,
        .dimensions = 2,
        .maximum_entries = 4,
        .maximum_value_size = 4,
    }).Trait;
    const Binding = Trait.Binding(Backend);
    const Box = Binding.Proxy.BoundingBox;

    try std.testing.expect(Binding.Tree == fullaz.spatial.rtree.RTree(Binding.Model));

    var device = try Device.init(std.testing.allocator, 4096);
    defer device.deinit();
    var inner = try InnerCache.init(&device, std.testing.allocator, 8);
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
    try std.testing.expect(@TypeOf(runtime.model) == Binding.Model);
    try std.testing.expect(@TypeOf(runtime.tree) == Binding.Tree);

    const inactive = Binding.proxy(&runtime);
    var value: [4]u8 = undefined;
    std.mem.writeInt(u32, &value, 7, .little);
    try std.testing.expectError(
        error.TransactionInactive,
        inactive.insert(Box.initWith(.{ 2, 2 }, .{ 4, 4 }), &value),
    );
    const inactive_matches = MatchesValue{ .value = 7 };
    try std.testing.expectError(
        error.TransactionInactive,
        inactive.remove(
            Box.initWith(.{ 2, 2 }, .{ 4, 4 }),
            &inactive_matches,
            MatchesValue.callback,
        ),
    );

    var transaction = try cache.begin();
    errdefer transaction.discard() catch {};
    const tree = Binding.proxy(&runtime);
    try tree.insert(Box.initWith(.{ 2, 2 }, .{ 4, 4 }), &value);
    try transaction.commit();
    try std.testing.expectError(
        error.TransactionInactive,
        tree.insert(Box.initWith(.{ 5, 5 }, .{ 6, 6 }), &value),
    );

    var next_transaction = try cache.begin();
    errdefer next_transaction.discard() catch {};
    try std.testing.expectError(
        error.TransactionInactive,
        tree.insert(Box.initWith(.{ 5, 5 }, .{ 6, 6 }), &value),
    );
    try next_transaction.discard();

    const runtime_const: *const Binding.Runtime = &runtime;
    const tree_const = Binding.proxyConst(runtime_const);
    try std.testing.expect(tree_const == &runtime.const_proxy);
    try std.testing.expect(!@hasDecl(Binding.ConstProxy, "insert"));
    try std.testing.expect(!@hasDecl(Binding.ConstProxy, "remove"));

    var collector = Collector{};
    try tree_const.search(Box.initWith(.{ 0, 0 }, .{ 10, 10 }), &collector, Collector.callback);
    try std.testing.expectEqual(@as(usize, 1), collector.count);
    try std.testing.expectEqual(@as(u32, 7), collector.sum);

    var intersecting_collector = Collector{};
    try tree_const.searchIntersecting(
        Box.initWith(.{ 4, 2 }, .{ 5, 4 }),
        &intersecting_collector,
        Collector.callback,
    );
    try std.testing.expectEqual(@as(usize, 1), intersecting_collector.count);

    var failing = FailingCollector{};
    try std.testing.expectError(
        error.Stopped,
        tree_const.search(Box.initWith(.{ 0, 0 }, .{ 10, 10 }), &failing, FailingCollector.callback),
    );

    var invalid_transaction = try cache.begin();
    errdefer invalid_transaction.discard() catch {};
    const invalid_tree = Binding.proxy(&runtime);
    try std.testing.expectError(
        error.InvalidBoundingBox,
        invalid_tree.insert(Box.initWith(.{ 4, 4 }, .{ 2, 2 }), &value),
    );
    try std.testing.expectError(error.TransactionRollbackOnly, invalid_transaction.commit());
    try invalid_transaction.discard();

    var removal_transaction = try cache.begin();
    errdefer removal_transaction.discard() catch {};
    const matches = MatchesValue{ .value = 7 };
    try std.testing.expect(
        try Binding.proxy(&runtime).remove(
            Box.initWith(.{ 2, 2 }, .{ 4, 4 }),
            &matches,
            MatchesValue.callback,
        ),
    );
    try removal_transaction.commit();
}

test "fullaz-db: R-tree memory database commits and restores its root" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 })
        .add("spatial", fullaz_db.rtree(.{
        .Coord = i64,
        .dimensions = 2,
        .maximum_entries = 4,
        .maximum_value_size = 4,
    }));
    const Db = fullaz_db.MemoryDatabase(Schema);
    const Binding = Schema.trait("spatial").Binding(Db.BackendType);
    const Box = Binding.Proxy.BoundingBox;

    var database = try Db.init(std.testing.allocator, .{
        .page_size = 256,
        .cache_frames = 8,
    });
    defer database.deinit();

    var value: [4]u8 = undefined;
    std.mem.writeInt(u32, &value, 7, .little);
    {
        var transaction = try database.begin();
        defer transaction.deinit();
        try transaction.get("spatial").insert(Box.initWith(.{ 2, 2 }, .{ 4, 4 }), &value);
        try transaction.rollback();
    }
    try std.testing.expectEqual(@as(usize, 0), database.diagnostics().physical_page_count);

    {
        var transaction = try database.begin();
        defer transaction.deinit();
        try transaction.get("spatial").insert(Box.initWith(.{ 2, 2 }, .{ 4, 4 }), &value);
        try transaction.commit();
    }

    var collector = Collector{};
    try database.getConst("spatial").search(
        Box.initWith(.{ 0, 0 }, .{ 10, 10 }),
        &collector,
        Collector.callback,
    );
    try std.testing.expectEqual(@as(usize, 1), collector.count);
    try std.testing.expectEqual(@as(u32, 7), collector.sum);
}

test "fullaz-db: R-tree commits extreme integer boxes after a split" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 })
        .add("spatial", fullaz_db.rtree(.{
        .Coord = i64,
        .dimensions = 2,
        .maximum_entries = 4,
        .maximum_value_size = 4,
    }));
    const Db = fullaz_db.MemoryDatabase(Schema);
    const Binding = Schema.trait("spatial").Binding(Db.BackendType);
    const Box = Binding.Proxy.BoundingBox;
    const extreme = Box.initWith(
        .{ std.math.minInt(i64), std.math.minInt(i64) },
        .{ std.math.maxInt(i64), std.math.maxInt(i64) },
    );

    var database = try Db.init(std.testing.allocator, .{
        .page_size = 256,
        .cache_frames = 8,
    });
    defer database.deinit();

    {
        var transaction = try database.begin();
        defer transaction.deinit();
        for (0..5) |index| {
            var value: [4]u8 = undefined;
            std.mem.writeInt(u32, &value, @intCast(index), .little);
            try transaction.get("spatial").insert(extreme, &value);
        }
        try transaction.commit();
    }

    var values = ValuesCollector{};
    try database.getConst("spatial").search(extreme, &values, ValuesCollector.callback);
    for (0..5) |index| {
        try std.testing.expect(values.seen[index]);
    }
}

test "fullaz-db: R-tree memory database reclaims and reuses all pages" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 })
        .add("spatial", fullaz_db.rtree(.{
        .Coord = i64,
        .dimensions = 2,
        .maximum_entries = 4,
        .maximum_value_size = 4,
    }));
    const Db = fullaz_db.MemoryDatabase(Schema);
    const Binding = Schema.trait("spatial").Binding(Db.BackendType);
    const Box = Binding.Proxy.BoundingBox;

    var database = try Db.init(std.testing.allocator, .{
        .page_size = 256,
        .cache_frames = 32,
    });
    defer database.deinit();

    var transaction = try database.begin();
    defer transaction.deinit();
    const tree = transaction.get("spatial");
    for (0..8) |index| {
        var value: [4]u8 = undefined;
        std.mem.writeInt(u32, &value, @intCast(index), .little);
        const coordinate: i64 = @intCast(index * 10);
        try tree.insert(
            Box.initWith(.{ coordinate, 0 }, .{ coordinate + 1, 1 }),
            &value,
        );
    }
    const physical_page_count = database.diagnostics().physical_page_count;
    try std.testing.expect(physical_page_count > 1);

    var index: usize = 8;
    while (index > 0) {
        index -= 1;
        const matches = MatchesValue{ .value = @intCast(index) };
        const coordinate: i64 = @intCast(index * 10);
        try std.testing.expect(
            try tree.remove(
                Box.initWith(.{ coordinate, 0 }, .{ coordinate + 1, 1 }),
                &matches,
                MatchesValue.callback,
            ),
        );
    }
    try std.testing.expectEqual(physical_page_count, database.diagnostics().free_page_count);

    var value: [4]u8 = undefined;
    std.mem.writeInt(u32, &value, 99, .little);
    try tree.insert(Box.initWith(.{ 100, 0 }, .{ 101, 1 }), &value);
    try std.testing.expectEqual(physical_page_count, database.diagnostics().physical_page_count);
    try std.testing.expectEqual(physical_page_count - 1, database.diagnostics().free_page_count);
    try transaction.commit();
}

test "fullaz-db: R-tree memory database rolls back a failed root split" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 })
        .add("spatial", fullaz_db.rtree(.{
        .Coord = i64,
        .dimensions = 2,
        .maximum_entries = 4,
        .maximum_value_size = 4,
    }));
    const Db = fullaz_db.MemoryDatabase(Schema);
    const Binding = Schema.trait("spatial").Binding(Db.BackendType);
    const Box = Binding.Proxy.BoundingBox;

    var database = try Db.init(std.testing.allocator, .{
        .page_size = 256,
        .cache_frames = 2,
    });
    defer database.deinit();

    {
        var transaction = try database.begin();
        defer transaction.deinit();
        const tree = transaction.get("spatial");
        for (0..4) |index| {
            var value: [4]u8 = undefined;
            std.mem.writeInt(u32, &value, @intCast(index), .little);
            const coordinate: i64 = @intCast(index * 10);
            try tree.insert(
                Box.initWith(.{ coordinate, 0 }, .{ coordinate + 1, 1 }),
                &value,
            );
        }
        try transaction.commit();
    }

    const diagnostics_before = database.diagnostics();
    {
        var transaction = try database.begin();
        defer transaction.deinit();
        var value: [4]u8 = undefined;
        std.mem.writeInt(u32, &value, 4, .little);
        try std.testing.expectError(
            error.BatchTooLarge,
            transaction.get("spatial").insert(
                Box.initWith(.{ 40, 0 }, .{ 41, 1 }),
                &value,
            ),
        );
        try std.testing.expectError(error.TransactionRollbackOnly, transaction.commit());
        try transaction.rollback();
    }

    const diagnostics_after = database.diagnostics();
    try std.testing.expectEqual(diagnostics_before.physical_page_count, diagnostics_after.physical_page_count);
    try std.testing.expectEqual(diagnostics_before.device_page_count, diagnostics_after.device_page_count);
    try std.testing.expectEqual(diagnostics_before.free_page_count, diagnostics_after.free_page_count);

    var collector = Collector{};
    try database.getConst("spatial").search(
        Box.initWith(.{ -1, -1 }, .{ 100, 10 }),
        &collector,
        Collector.callback,
    );
    try std.testing.expectEqual(@as(usize, 4), collector.count);
    try std.testing.expectEqual(@as(u32, 6), collector.sum);

    var values = ValuesCollector{};
    try database.getConst("spatial").search(
        Box.initWith(.{ -1, -1 }, .{ 100, 10 }),
        &values,
        ValuesCollector.callback,
    );
    for (0..4) |index| {
        try std.testing.expect(values.seen[index]);
    }
    try std.testing.expect(!values.seen[4]);
}

test "fullaz-db: R-tree facade rejects non-finite float MBRs" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 })
        .add("spatial", fullaz_db.rtree(.{
        .Coord = f64,
        .dimensions = 2,
        .maximum_entries = 4,
        .maximum_value_size = 4,
    }));
    const Db = fullaz_db.MemoryDatabase(Schema);
    const Binding = Schema.trait("spatial").Binding(Db.BackendType);
    const Box = Binding.Proxy.BoundingBox;

    var database = try Db.init(std.testing.allocator, .{
        .page_size = 256,
        .cache_frames = 8,
    });
    defer database.deinit();

    var collector = Collector{};
    try std.testing.expectError(
        error.InvalidBoundingBox,
        database.getConst("spatial").search(
            Box.initWith(.{ std.math.nan(f64), 0.0 }, .{ 1.0, 1.0 }),
            &collector,
            Collector.callback,
        ),
    );

    var transaction = try database.begin();
    errdefer transaction.rollback() catch {};
    var value: [4]u8 = undefined;
    std.mem.writeInt(u32, &value, 7, .little);
    try std.testing.expectError(
        error.InvalidBoundingBox,
        transaction.get("spatial").insert(
            Box.initWith(.{ 0.0, 0.0 }, .{ std.math.inf(f64), 1.0 }),
            &value,
        ),
    );
    try std.testing.expectError(error.TransactionRollbackOnly, transaction.commit());
    try transaction.rollback();
}

test "fullaz-db: two R-tree components share reclamation and keep independent roots" {
    const Schema = fullaz_db.Schema(.{ .page_id = u32 })
        .add("left", fullaz_db.rtree(.{
            .Coord = i64,
            .dimensions = 2,
            .maximum_entries = 4,
            .maximum_value_size = 4,
        }))
        .add("right", fullaz_db.rtree(.{
        .Coord = i64,
        .dimensions = 2,
        .maximum_entries = 4,
        .maximum_value_size = 4,
    }));
    const Db = fullaz_db.MemoryDatabase(Schema);
    const Binding = Schema.trait("left").Binding(Db.BackendType);
    const Box = Binding.Proxy.BoundingBox;

    try std.testing.expect(
        Schema.pageKinds("left").endExclusive() == Schema.pageKinds("right").base,
    );

    var database = try Db.init(std.testing.allocator, .{
        .page_size = 256,
        .cache_frames = 32,
    });
    defer database.deinit();

    {
        var transaction = try database.begin();
        defer transaction.deinit();
        const left = transaction.get("left");
        const right = transaction.get("right");
        for (0..8) |index| {
            var value: [4]u8 = undefined;
            std.mem.writeInt(u32, &value, @intCast(index), .little);
            const coordinate: i64 = @intCast(index * 10);
            try left.insert(
                Box.initWith(.{ coordinate, 0 }, .{ coordinate + 1, 1 }),
                &value,
            );
        }
        var right_value: [4]u8 = undefined;
        std.mem.writeInt(u32, &right_value, 15, .little);
        try right.insert(Box.initWith(.{ 100, 0 }, .{ 101, 1 }), &right_value);
        try transaction.commit();
    }

    var left_values = ValuesCollector{};
    try database.getConst("left").search(
        Box.initWith(.{ -1, -1 }, .{ 100, 10 }),
        &left_values,
        ValuesCollector.callback,
    );
    for (0..8) |index| {
        try std.testing.expect(left_values.seen[index]);
    }
    var right_values = ValuesCollector{};
    try database.getConst("right").search(
        Box.initWith(.{ 99, -1 }, .{ 102, 2 }),
        &right_values,
        ValuesCollector.callback,
    );
    try std.testing.expect(right_values.seen[15]);

    const physical_page_count = database.diagnostics().physical_page_count;
    {
        var transaction = try database.begin();
        defer transaction.deinit();
        const left = transaction.get("left");
        var index: usize = 8;
        while (index > 0) {
            index -= 1;
            const coordinate: i64 = @intCast(index * 10);
            const matches = MatchesValue{ .value = @intCast(index) };
            try std.testing.expect(try left.remove(
                Box.initWith(.{ coordinate, 0 }, .{ coordinate + 1, 1 }),
                &matches,
                MatchesValue.callback,
            ));
        }
        try transaction.commit();
    }
    try std.testing.expect(database.diagnostics().free_page_count > 0);

    {
        var transaction = try database.begin();
        defer transaction.deinit();
        var value: [4]u8 = undefined;
        std.mem.writeInt(u32, &value, 14, .little);
        try transaction.get("right").insert(
            Box.initWith(.{ 110, 0 }, .{ 111, 1 }),
            &value,
        );
        try std.testing.expectEqual(physical_page_count, database.diagnostics().physical_page_count);
        try transaction.commit();
    }
}
