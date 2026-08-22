const std = @import("std");
const dispatch = @import("dispatch");

fn memoryDatabase() !dispatch.MemoryDatabase {
    return dispatch.MemoryDatabase.init(std.testing.allocator, .{
        .page_size = 512,
        .cache_frames = 32,
    });
}

test "dispatch scenario commits every component and rolls back atomically" {
    try dispatch.runMemory(std.testing.allocator);
}

test "addOrder inserts and nextDue returns the earliest due id" {
    var database = try memoryDatabase();
    defer database.deinit();

    try dispatch.addOrder(dispatch.MemoryDatabase, &database, .{
        .id = "20260010".*,
        .value = "open|high|north pump",
        .low = .{ 10, 10 },
        .high = .{ 20, 20 },
    });
    try dispatch.addOrder(dispatch.MemoryDatabase, &database, .{
        .id = "20260005".*,
        .value = "open|medium|west valve",
        .low = .{ 30, 10 },
        .high = .{ 40, 20 },
    });

    try std.testing.expectEqual(
        @as(u64, 2),
        try database.getConst("dispatch_queue").count(),
    );

    const next = (try dispatch.nextDue(dispatch.MemoryDatabase, &database)).?;
    try std.testing.expectEqualStrings("20260005", &next);
}

test "ordersInArea returns only ids overlapping the query window" {
    var database = try memoryDatabase();
    defer database.deinit();

    try dispatch.addOrder(dispatch.MemoryDatabase, &database, .{
        .id = "00000001".*,
        .value = "open|high|north pump",
        .low = .{ 10, 10 },
        .high = .{ 20, 20 },
    });
    try dispatch.addOrder(dispatch.MemoryDatabase, &database, .{
        .id = "00000002".*,
        .value = "open|medium|west valve",
        .low = .{ 30, 10 },
        .high = .{ 40, 20 },
    });
    try dispatch.addOrder(dispatch.MemoryDatabase, &database, .{
        .id = "00000003".*,
        .value = "open|critical|river sensor",
        .low = .{ 10, 30 },
        .high = .{ 20, 40 },
    });

    var found = try dispatch.ordersInArea(
        dispatch.MemoryDatabase,
        &database,
        std.testing.allocator,
        .{ 0, 0 },
        .{ 25, 25 },
    );
    defer found.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expectEqualStrings("00000001", &found.items[0]);
}

test "nextDue returns null when the queue is empty" {
    var database = try memoryDatabase();
    defer database.deinit();

    try std.testing.expectEqual(
        @as(?[8]u8, null),
        try dispatch.nextDue(dispatch.MemoryDatabase, &database),
    );
}

test "completeNext removes the earliest order and records it" {
    var database = try memoryDatabase();
    defer database.deinit();

    try dispatch.addOrder(dispatch.MemoryDatabase, &database, .{
        .id = "00000010".*,
        .value = "open|medium|west valve",
        .low = .{ 30, 10 },
        .high = .{ 40, 20 },
    });
    try dispatch.addOrder(dispatch.MemoryDatabase, &database, .{
        .id = "00000005".*,
        .value = "open|high|north pump",
        .low = .{ 10, 10 },
        .high = .{ 20, 20 },
    });

    const done = (try dispatch.completeNext(dispatch.MemoryDatabase, &database)).?;
    try std.testing.expectEqualStrings("00000005", &done);

    try std.testing.expectEqual(
        @as(u64, 1),
        try database.getConst("dispatch_queue").count(),
    );

    const remaining = (try dispatch.nextDue(dispatch.MemoryDatabase, &database)).?;
    try std.testing.expectEqualStrings("00000010", &remaining);

    try std.testing.expect(
        (try database.getConst("orders").find("00000005")) == null,
    );

    var found = try dispatch.ordersInArea(
        dispatch.MemoryDatabase,
        &database,
        std.testing.allocator,
        .{ 0, 0 },
        .{ 100, 100 },
    );
    defer found.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expectEqualStrings("00000010", &found.items[0]);

    var audit: [64]u8 = undefined;
    const audit_len = try database.getConst("audit_log").readAt(0, &audit);
    try std.testing.expectEqualStrings("completed:00000005\n", audit[0..audit_len]);
}

test "snapshotOrders returns added orders with areas, sorted by id" {
    var database = try memoryDatabase();
    defer database.deinit();

    try dispatch.addOrder(dispatch.MemoryDatabase, &database, .{
        .id = "00000002".*,
        .value = "open|medium|west valve",
        .low = .{ 30, 10 },
        .high = .{ 40, 20 },
    });
    try dispatch.addOrder(dispatch.MemoryDatabase, &database, .{
        .id = "00000001".*,
        .value = "open|high|north pump",
        .low = .{ 10, 10 },
        .high = .{ 20, 20 },
    });

    var orders = try dispatch.snapshotOrders(dispatch.MemoryDatabase, &database, std.testing.allocator);
    defer orders.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), orders.items.len);
    try std.testing.expectEqualStrings("00000001", &orders.items[0].id);
    try std.testing.expectEqualStrings("00000002", &orders.items[1].id);
    try std.testing.expectEqual(@as(f32, 10), orders.items[0].low[0]);
    try std.testing.expectEqual(@as(f32, 20), orders.items[0].high[0]);
    try std.testing.expectEqualStrings(
        "open|high|north pump",
        orders.items[0].value[0..orders.items[0].value_len],
    );
    for (orders.items[0].value[orders.items[0].value_len..]) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "addOrder rejects non-finite and inverted service areas" {
    var database = try memoryDatabase();
    defer database.deinit();

    try std.testing.expectError(
        error.InvalidArea,
        dispatch.addOrder(dispatch.MemoryDatabase, &database, .{
            .id = "00000001".*,
            .value = "open|high|bad bounds",
            .low = .{ 2, 2 },
            .high = .{ 1, 3 },
        }),
    );
    try std.testing.expectError(
        error.InvalidArea,
        dispatch.addOrder(dispatch.MemoryDatabase, &database, .{
            .id = "00000002".*,
            .value = "open|high|nan bounds",
            .low = .{ std.math.nan(f32), 2 },
            .high = .{ 3, 4 },
        }),
    );
    try std.testing.expectEqual(@as(u64, 0), try database.getConst("dispatch_queue").count());
}

test "inspectPages classifies pages and deviceBytes matches the image size" {
    var database = try memoryDatabase();
    defer database.deinit();

    try dispatch.addOrder(dispatch.MemoryDatabase, &database, .{
        .id = "00000001".*,
        .value = "open|high|north pump",
        .low = .{ 10, 10 },
        .high = .{ 20, 20 },
    });

    const diag = database.diagnostics();
    try std.testing.expectEqual(
        diag.device_page_count * diag.page_size,
        database.deviceBytes().len,
    );

    var pages = try dispatch.inspectPages(
        database.deviceBytes(),
        database.diagnostics().page_size,
        database.freePageIds(),
        std.testing.allocator,
    );
    defer pages.deinit(std.testing.allocator);

    try std.testing.expectEqual(diag.device_page_count, pages.items.len);

    var classified = false;
    for (pages.items) |page| {
        if (page.component != 0xFF) {
            classified = true;
        }
    }
    try std.testing.expect(classified);
}

test "inspectPages marks free pages after completing orders" {
    var database = try memoryDatabase();
    defer database.deinit();

    try dispatch.addOrder(dispatch.MemoryDatabase, &database, .{
        .id = "00000001".*,
        .value = "open|high|north pump",
        .low = .{ 10, 10 },
        .high = .{ 20, 20 },
    });
    try dispatch.addOrder(dispatch.MemoryDatabase, &database, .{
        .id = "00000002".*,
        .value = "open|medium|west valve",
        .low = .{ 30, 10 },
        .high = .{ 40, 20 },
    });
    _ = try dispatch.completeNext(dispatch.MemoryDatabase, &database);

    var pages = try dispatch.inspectPages(
        database.deviceBytes(),
        database.diagnostics().page_size,
        database.freePageIds(),
        std.testing.allocator,
    );
    defer pages.deinit(std.testing.allocator);

    for (database.freePageIds()) |free_pid| {
        var matched = false;
        for (pages.items) |page| {
            if (page.pid == free_pid) {
                try std.testing.expectEqual(@as(u8, 0xFF), page.component);
                matched = true;
            }
        }
        try std.testing.expect(matched);
    }
}

const Collector = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,

    pub fn writeAll(self: *Collector, bytes: []const u8) !void {
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn print(self: *Collector, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.bufPrint(self.buf[self.len..], fmt, args);
        self.len += s.len;
    }
};

test "cli commands drive the dispatch database" {
    var database = try memoryDatabase();
    defer database.deinit();

    var cli = dispatch.cli.Cli(dispatch.MemoryDatabase).init(&database, std.testing.allocator);
    var col = Collector{};

    try cli.execTokens(&.{ "add", "00000001", "60", "24", "0.5", "open|high|north pump" }, &col);
    try cli.execTokens(&.{ "add", "00000002", "61", "25", "0.5", "open|medium|west valve" }, &col);
    try std.testing.expectError(
        error.OrderAlreadyExists,
        cli.execTokens(&.{ "add", "00000001", "60", "24", "0.5", "duplicate" }, &col),
    );

    col.len = 0;
    try cli.execTokens(&.{"top"}, &col);
    try std.testing.expectEqualStrings("next due: 00000001\n", col.buf[0..col.len]);

    col.len = 0;
    try cli.execTokens(&.{"complete"}, &col);
    try std.testing.expectEqualStrings("completed: 00000001\n", col.buf[0..col.len]);

    col.len = 0;
    try cli.execTokens(&.{"list"}, &col);
    try std.testing.expectEqualStrings(
        "00000002  open|medium|west valve  [60.50,24.50]..[61.50,25.50]\n",
        col.buf[0..col.len],
    );

    col.len = 0;
    try cli.execTokens(&.{ "area", "61", "25", "0.5" }, &col);
    try std.testing.expectEqualStrings("00000002\n", col.buf[0..col.len]);

    col.len = 0;
    try cli.execTokens(&.{ "area", "10", "10", "0.5" }, &col);
    try std.testing.expectEqualStrings("no orders\n", col.buf[0..col.len]);

    col.len = 0;
    try cli.execTokens(&.{"bogus"}, &col);
    try std.testing.expectEqualStrings("unknown command: bogus\n", col.buf[0..col.len]);
}
