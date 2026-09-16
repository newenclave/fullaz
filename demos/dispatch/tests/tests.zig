const std = @import("std");
const dispatch = @import("dispatch");

fn memoryDatabase() !dispatch.MemoryDatabase {
    return dispatch.MemoryDatabase.init(std.testing.allocator, .{
        .page_size = 512,
        .cache_frames = 32,
    });
}

fn initializedDatabase() !dispatch.MemoryDatabase {
    var database = try memoryDatabase();
    errdefer database.deinit();
    try dispatch.initializeSimulation(dispatch.MemoryDatabase, &database, .{
        .latitude = 60.1699,
        .longitude = 24.9384,
    });
    return database;
}

fn completeActive(database: *dispatch.MemoryDatabase) !void {
    for (0..dispatch.service_seconds / dispatch.tick_seconds + 1) |_| {
        try dispatch.stepSimulation(dispatch.MemoryDatabase, database);
    }
}

fn expectSequence(actual: []const [8]u8, expected: []const [8]u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_id, actual_id| {
        try std.testing.expectEqual(expected_id, actual_id);
    }
}

fn findOrder(orders: []const dispatch.OrderSnapshot, id: [8]u8) ?dispatch.OrderSnapshot {
    for (orders) |order| {
        if (std.mem.eql(u8, &order.id, &id)) {
            return order;
        }
    }
    return null;
}

test "initialization creates an idle simulation at its base" {
    var database = try memoryDatabase();
    defer database.deinit();

    const base = dispatch.Position{ .latitude = 60.1699, .longitude = 24.9384 };
    try dispatch.initializeSimulation(dispatch.MemoryDatabase, &database, base);

    const snapshot = try dispatch.snapshotSimulation(dispatch.MemoryDatabase, &database);
    try std.testing.expectEqual(@as(u8, 1), snapshot.configured);
    try std.testing.expectEqual(@as(u8, 0), snapshot.auto_orders);
    try std.testing.expectEqual(@intFromEnum(dispatch.Phase.idle), snapshot.phase);
    try std.testing.expectEqual(@as([2]f32, .{ base.latitude, base.longitude }), snapshot.base);
    try std.testing.expectEqual(snapshot.base, snapshot.crew);
    try std.testing.expectEqual(@as(u64, 0), snapshot.model_seconds);
    try std.testing.expectEqual(@as(u32, 0), snapshot.pending_count);
    try std.testing.expectEqual(@as(u32, 0), snapshot.suspended_count);
    try std.testing.expectError(
        error.SimulationAlreadyConfigured,
        dispatch.initializeSimulation(dispatch.MemoryDatabase, &database, base),
    );
    try dispatch.validateSimulation(dispatch.MemoryDatabase, &database, std.testing.allocator);
}

test "normal orders retain FIFO request order regardless of descriptions" {
    var database = try initializedDatabase();
    defer database.deinit();

    const first = try dispatch.addOrder(dispatch.MemoryDatabase, &database, .{
        .latitude = 60.1700,
        .longitude = 24.9384,
    }, "zebra request");
    const second = try dispatch.addOrder(dispatch.MemoryDatabase, &database, .{
        .latitude = 60.1701,
        .longitude = 24.9384,
    }, "aardvark request");
    const third = try dispatch.addOrder(dispatch.MemoryDatabase, &database, .{
        .latitude = 60.1702,
        .longitude = 24.9384,
    }, "same description");

    var pending = try dispatch.snapshotSequence(
        dispatch.MemoryDatabase,
        &database,
        "pending",
        std.testing.allocator,
    );
    defer pending.deinit(std.testing.allocator);
    try expectSequence(pending.items, &.{ second, third });

    try completeActive(&database);
    const snapshot = try dispatch.snapshotSimulation(dispatch.MemoryDatabase, &database);
    try std.testing.expectEqual(second, snapshot.active_id);

    var remaining = try dispatch.snapshotSequence(
        dispatch.MemoryDatabase,
        &database,
        "pending",
        std.testing.allocator,
    );
    defer remaining.deinit(std.testing.allocator);
    try expectSequence(remaining.items, &.{third});
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
}

test "nested emergencies suspend and resume work in LIFO order" {
    var database = try initializedDatabase();
    defer database.deinit();

    const normal = try dispatch.addOrder(dispatch.MemoryDatabase, &database, .{
        .latitude = 60.1699,
        .longitude = 24.9384,
    }, "normal work");
    try dispatch.stepSimulation(dispatch.MemoryDatabase, &database);
    try dispatch.stepSimulation(dispatch.MemoryDatabase, &database);

    var before = try dispatch.snapshotOrders(dispatch.MemoryDatabase, &database, std.testing.allocator);
    defer before.deinit(std.testing.allocator);
    const remaining_before_suspension = findOrder(before.items, normal).?.remaining_service_seconds;

    const first_emergency = try dispatch.addEmergency(dispatch.MemoryDatabase, &database, .{
        .latitude = 60.1700,
        .longitude = 24.9384,
    }, "first emergency");
    const second_emergency = try dispatch.addEmergency(dispatch.MemoryDatabase, &database, .{
        .latitude = 60.1701,
        .longitude = 24.9384,
    }, "second emergency");

    var suspended = try dispatch.snapshotSequence(
        dispatch.MemoryDatabase,
        &database,
        "suspended",
        std.testing.allocator,
    );
    defer suspended.deinit(std.testing.allocator);
    try expectSequence(suspended.items, &.{ first_emergency, normal });

    var orders = try dispatch.snapshotOrders(dispatch.MemoryDatabase, &database, std.testing.allocator);
    defer orders.deinit(std.testing.allocator);
    const normal_status = findOrder(orders.items, normal).?.status;
    const first_emergency_status = findOrder(orders.items, first_emergency).?.status;
    const second_emergency_status = findOrder(orders.items, second_emergency).?.status;
    try std.testing.expect(normal_status != second_emergency_status);
    try std.testing.expectEqual(normal_status, first_emergency_status);

    try completeActive(&database);
    var after_first_resume = try dispatch.snapshotSimulation(dispatch.MemoryDatabase, &database);
    try std.testing.expectEqual(first_emergency, after_first_resume.active_id);

    try completeActive(&database);
    after_first_resume = try dispatch.snapshotSimulation(dispatch.MemoryDatabase, &database);
    try std.testing.expectEqual(normal, after_first_resume.active_id);

    var resumed_orders = try dispatch.snapshotOrders(dispatch.MemoryDatabase, &database, std.testing.allocator);
    defer resumed_orders.deinit(std.testing.allocator);
    const resumed = findOrder(resumed_orders.items, normal).?;
    try std.testing.expectEqual(remaining_before_suspension, resumed.remaining_service_seconds);
    try std.testing.expectEqual(second_emergency_status, resumed.status);
}

test "a new order diverts the crew while it is returning to base" {
    var database = try initializedDatabase();
    defer database.deinit();

    _ = try dispatch.addOrder(dispatch.MemoryDatabase, &database, .{
        .latitude = 60.1700,
        .longitude = 24.9384,
    }, "distant work");
    try completeActive(&database);

    const returning = try dispatch.snapshotSimulation(dispatch.MemoryDatabase, &database);
    try std.testing.expectEqual(@intFromEnum(dispatch.Phase.returning), returning.phase);
    try std.testing.expect(returning.crew[0] != returning.base[0]);

    const diversion = try dispatch.addOrder(dispatch.MemoryDatabase, &database, .{
        .latitude = 60.1710,
        .longitude = 24.9384,
    }, "diversion");
    const diverted = try dispatch.snapshotSimulation(dispatch.MemoryDatabase, &database);
    try std.testing.expectEqual(@intFromEnum(dispatch.Phase.travelling), diverted.phase);
    try std.testing.expectEqual(diversion, diverted.active_id);
}

test "automatic orders remain disabled until enabled and advance on ticks" {
    var database = try initializedDatabase();
    defer database.deinit();

    for (0..dispatch.auto_order_interval_seconds / dispatch.tick_seconds) |_| {
        try dispatch.stepSimulation(dispatch.MemoryDatabase, &database);
    }
    var snapshot = try dispatch.snapshotSimulation(dispatch.MemoryDatabase, &database);
    try std.testing.expectEqual(@as(u64, dispatch.auto_order_interval_seconds), snapshot.model_seconds);
    try std.testing.expectEqual(@as(u32, 0), snapshot.pending_count);
    var orders = try dispatch.snapshotOrders(dispatch.MemoryDatabase, &database, std.testing.allocator);
    defer orders.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), orders.items.len);

    try dispatch.setAutoOrders(dispatch.MemoryDatabase, &database, true);
    for (0..dispatch.auto_order_interval_seconds / dispatch.tick_seconds - 1) |_| {
        try dispatch.stepSimulation(dispatch.MemoryDatabase, &database);
    }
    snapshot = try dispatch.snapshotSimulation(dispatch.MemoryDatabase, &database);
    try std.testing.expectEqual(@as(u8, 1), snapshot.auto_orders);
    try std.testing.expectEqual(@as(u32, dispatch.tick_seconds), snapshot.auto_remaining_seconds);

    try dispatch.stepSimulation(dispatch.MemoryDatabase, &database);
    snapshot = try dispatch.snapshotSimulation(dispatch.MemoryDatabase, &database);
    try std.testing.expectEqual(@as(u64, dispatch.auto_order_interval_seconds * 2), snapshot.model_seconds);
    try std.testing.expectEqual(@as(u32, dispatch.auto_order_interval_seconds), snapshot.auto_remaining_seconds);
    try std.testing.expect(!std.mem.allEqual(u8, &snapshot.active_id, 0));
}

test "invalid positions and requests outside the service zone are rejected" {
    var database = try memoryDatabase();
    defer database.deinit();

    try std.testing.expectError(
        error.InvalidPosition,
        dispatch.initializeSimulation(dispatch.MemoryDatabase, &database, .{
            .latitude = std.math.nan(f32),
            .longitude = 0,
        }),
    );
    try dispatch.initializeSimulation(dispatch.MemoryDatabase, &database, .{
        .latitude = 60.1699,
        .longitude = 24.9384,
    });
    try std.testing.expectError(
        error.InvalidPosition,
        dispatch.addOrder(dispatch.MemoryDatabase, &database, .{ .latitude = 91, .longitude = 0 }, "bad latitude"),
    );
    try std.testing.expectError(
        error.OutsideServiceArea,
        dispatch.addOrder(dispatch.MemoryDatabase, &database, .{ .latitude = 61, .longitude = 24.9384 }, "too far"),
    );
    try std.testing.expectError(
        error.InvalidArea,
        dispatch.ordersInArea(dispatch.MemoryDatabase, &database, std.testing.allocator, .{
            .latitude = 61,
            .longitude = 25,
        }, .{
            .latitude = 60,
            .longitude = 24,
        }),
    );
}

test "snapshots, history, and page inspection describe public dispatch state" {
    var database = try initializedDatabase();
    defer database.deinit();

    const id = try dispatch.addOrder(dispatch.MemoryDatabase, &database, .{
        .latitude = 60.1700,
        .longitude = 24.9384,
    }, "snapshot request");
    var orders = try dispatch.snapshotOrders(dispatch.MemoryDatabase, &database, std.testing.allocator);
    defer orders.deinit(std.testing.allocator);
    const order = findOrder(orders.items, id).?;
    try std.testing.expectEqualStrings("snapshot request", order.description[0..order.description_length]);
    try std.testing.expectEqual(@as([2]f32, .{ 60.1700, 24.9384 }), order.position);

    var history = try dispatch.snapshotHistory(dispatch.MemoryDatabase, &database, std.testing.allocator);
    defer history.deinit(std.testing.allocator);
    try std.testing.expect(history.items.len >= 4);
    try std.testing.expectEqual(id, history.items[history.items.len - 1].order_id);

    const diagnostics = database.diagnostics();
    try std.testing.expectEqual(diagnostics.device_page_count * diagnostics.page_size, database.deviceBytes().len);
    var pages = try dispatch.inspectPages(
        database.deviceBytes(),
        diagnostics.page_size,
        database.freePageIds(),
        std.testing.allocator,
    );
    defer pages.deinit(std.testing.allocator);
    try std.testing.expectEqual(diagnostics.device_page_count, pages.items.len);
    for (pages.items) |page| {
        try std.testing.expectEqual(diagnostics.page_size, page.capacity);
    }
    try dispatch.validateSimulation(dispatch.MemoryDatabase, &database, std.testing.allocator);
}
