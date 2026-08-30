const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

fn compare(_: void, left: []const u8, right: []const u8) std.math.Order {
    return std.mem.order(u8, left, right);
}

fn heapCompare(_: void, left: []const u8, right: []const u8) std.math.Order {
    return std.mem.order(u8, left, right);
}

pub const Schema = fullaz_db.Schema(.{ .page_id = u32 })
    .add("orders", fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 8,
        .maximum_value_size = 64,
    }))
    .add("by_status_due", fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 2,
        .maximum_key_size = 17,
        .maximum_value_size = 0,
    }))
    .add("service_areas", fullaz_db.rtree(.{
        .Coord = f32,
        .dimensions = 2,
        .maximum_entries = 8,
        .maximum_value_size = 8,
    }))
    .add("dispatch_queue", fullaz_db.slotHeap(.{
        .compare = heapCompare,
        .CompareContext = void,
        .comparator_id = 3,
        .maximum_key_size = 8,
        .maximum_value_size = 0,
        .maximum_level = 8,
    }))
    .add("audit_log", fullaz_db.chainStore(.{}))
    .add("runbook", fullaz_db.weightedSequence(.{ .maximum_chunk_size = 64 }));

pub const MemoryDatabase = fullaz_db.MemoryDatabase(Schema);

pub const cli = @import("cli.zig");

/// A work order. `id` is both the order identity and its sortable due time:
/// it keys `orders`, `by_status_due`, `service_areas`, and `dispatch_queue`.
pub const Order = struct {
    id: [8]u8,
    value: []const u8,
    low: [2]f32,
    high: [2]f32,
};

fn areaBox(comptime DatabaseT: type) type {
    return Schema.trait("service_areas").Binding(DatabaseT.BackendType).Proxy.BoundingBox;
}

fn validateArea(low: [2]f32, high: [2]f32) !void {
    inline for (0..2) |axis| {
        if (!std.math.isFinite(low[axis]) or !std.math.isFinite(high[axis]) or low[axis] > high[axis]) {
            return error.InvalidArea;
        }
    }
}

/// Adds a work order to every composed component in one transaction.
pub fn addOrder(comptime DatabaseT: type, database: *DatabaseT, order: Order) !void {
    try validateArea(order.low, order.high);
    var transaction = try database.begin();
    defer transaction.deinit();

    if (!try transaction.get("orders").insert(&order.id, order.value)) {
        return error.OrderAlreadyExists;
    }
    if (!try transaction.get("by_status_due").insert(&order.id, "")) {
        return error.OrderAlreadyExists;
    }
    try transaction.get("service_areas").insert(
        areaBox(DatabaseT).initWith(order.low, order.high),
        &order.id,
    );
    try transaction.get("dispatch_queue").push(&order.id, "");

    try transaction.commit();
}

/// Returns the ids of orders whose service area intersects the query window.
pub fn ordersInArea(
    comptime DatabaseT: type,
    database: *const DatabaseT,
    allocator: std.mem.Allocator,
    low: [2]f32,
    high: [2]f32,
) !std.ArrayList([8]u8) {
    try validateArea(low, high);
    const Box = areaBox(DatabaseT);
    const Collect = struct {
        allocator: std.mem.Allocator,
        ids: std.ArrayList([8]u8),

        fn handle(self: *@This(), mbr: Box, value: []const u8) void {
            _ = mbr;
            self.ids.append(self.allocator, value[0..8].*) catch @panic("OOM collecting area order ids");
        }
    };
    var collect = Collect{
        .allocator = allocator,
        .ids = .empty,
    };
    errdefer collect.ids.deinit(allocator);

    try database.getConst("service_areas").searchIntersecting(
        Box.initWith(low, high),
        &collect,
        Collect.handle,
    );
    return collect.ids;
}

/// Returns the next order id by due time, or null when the queue is empty.
pub fn nextDue(comptime DatabaseT: type, database: *const DatabaseT) !?[8]u8 {
    const queue = database.getConst("dispatch_queue");
    if (try queue.isEmpty()) {
        return null;
    }
    var peek = try queue.top();
    defer peek.deinit();
    const key = try peek.key();
    return key[0..8].*;
}

/// Completes the next due order: pops it off the queue, removes it from every
/// component, and appends an audit entry. Returns the completed id, or null.
pub fn completeNext(comptime DatabaseT: type, database: *DatabaseT) !?[8]u8 {
    var transaction = try database.begin();
    defer transaction.deinit();

    const queue = transaction.get("dispatch_queue");
    if (try queue.isEmpty()) {
        return null;
    }

    var id: [8]u8 = undefined;
    {
        var peek = try queue.top();
        defer peek.deinit();
        const key = try peek.key();
        id = key[0..8].*;
    }

    try queue.pop();
    _ = try transaction.get("orders").remove(&id);
    _ = try transaction.get("by_status_due").remove(&id);

    const Box = areaBox(DatabaseT);
    const Matches = struct {
        id: [8]u8,
        fn call(ctx: *const @This(), mbr: Box, value: []const u8) bool {
            _ = mbr;
            return std.mem.eql(u8, value, &ctx.id);
        }
    };
    const matches = Matches{ .id = id };
    _ = try transaction.get("service_areas").remove(
        Box.initWith(
            .{ -std.math.floatMax(f32), -std.math.floatMax(f32) },
            .{ std.math.floatMax(f32), std.math.floatMax(f32) },
        ),
        &matches,
        Matches.call,
    );

    try transaction.get("audit_log").append("completed:");
    try transaction.get("audit_log").append(&id);
    try transaction.get("audit_log").append("\n");

    try transaction.commit();
    return id;
}

/// A point-in-time copy of one order for the browser renderer.
pub const OrderSnapshot = extern struct {
    id: [8]u8,
    value: [64]u8,
    value_len: u8,
    low: [2]f32,
    high: [2]f32,
};

/// Returns every order with its service area, sorted by id.
pub fn snapshotOrders(
    comptime DatabaseT: type,
    database: *const DatabaseT,
    allocator: std.mem.Allocator,
) !std.ArrayList(OrderSnapshot) {
    const Box = areaBox(DatabaseT);
    const Collect = struct {
        db: *const DatabaseT,
        allocator: std.mem.Allocator,
        snapshots: std.ArrayList(OrderSnapshot),

        fn handle(self: *@This(), mbr: Box, value: []const u8) void {
            var snapshot = OrderSnapshot{
                .id = value[0..8].*,
                .value = [_]u8{0} ** 64,
                .value_len = 0,
                .low = mbr.low,
                .high = mbr.high,
            };
            if (self.db.getConst("orders").find(value[0..8]) catch @panic("OOM reading order")) |found_iterator| {
                var iterator = found_iterator;
                defer iterator.deinit();
                const entry = (iterator.get() catch @panic("corrupt order iterator")).?;
                const value_len = @min(entry.value.len, snapshot.value.len);
                snapshot.value_len = @intCast(value_len);
                @memcpy(snapshot.value[0..value_len], entry.value[0..value_len]);
            }
            self.snapshots.append(self.allocator, snapshot) catch @panic("OOM collecting order snapshots");
        }
    };
    var collect = Collect{
        .db = database,
        .allocator = allocator,
        .snapshots = .empty,
    };
    errdefer collect.snapshots.deinit(allocator);

    try database.getConst("service_areas").search(
        Box.initWith(
            .{ -std.math.floatMax(f32), -std.math.floatMax(f32) },
            .{ std.math.floatMax(f32), std.math.floatMax(f32) },
        ),
        &collect,
        Collect.handle,
    );

    var items = collect.snapshots.items;
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and
            std.mem.order(u8, &items[j - 1].id, &items[j].id) == .gt) : (j -= 1)
        {
            std.mem.swap(OrderSnapshot, &items[j - 1], &items[j]);
        }
    }
    return collect.snapshots;
}

/// One physical page of the in-memory image, classified for the inspector.
pub const PageInfo = extern struct {
    pid: u32,
    kind: u16,
    component: u8,
    role: u8,
    used: u32,
    capacity: u32,
};

fn classifyKind(kind: u16) ?struct { component: u8, role: u8 } {
    inline for (Schema.fields, 0..) |field, component_index| {
        var role_index: usize = 0;
        while (role_index < field.page_kinds.count) : (role_index += 1) {
            if (field.page_kinds.kindAt(role_index).? == kind) {
                return .{
                    .component = @intCast(component_index),
                    .role = @intCast(role_index),
                };
            }
        }
    }
    return null;
}

/// Scans every physical page of an image and reports its kind, owning
/// component, and role. A page is free when its kind is the sentinel 0xFFFF
/// (a persisted `freed` page) or its id is in `free_pages`. Free pages report
/// component/role 0xFF.
pub fn inspectPages(
    device_bytes: []const u8,
    page_size: usize,
    free_pages: []const Schema.PageId,
    allocator: std.mem.Allocator,
) !std.ArrayList(PageInfo) {
    const HeaderView = fullaz.page.header.View(Schema.PageId, u16, .little, true);
    const page_count = device_bytes.len / page_size;

    var result = std.ArrayList(PageInfo).empty;
    errdefer result.deinit(allocator);

    for (0..page_count) |index| {
        const pid: u32 = @intCast(index);
        const page = device_bytes[index * page_size .. (index + 1) * page_size];
        const is_free_list = blk: {
            for (free_pages) |free_pid| {
                if (free_pid == pid) {
                    break :blk true;
                }
            }
            break :blk false;
        };

        var info = PageInfo{
            .pid = pid,
            .kind = 0,
            .component = 0xFF,
            .role = 0xFF,
            .used = 0,
            .capacity = @intCast(page.len),
        };

        const header = HeaderView.init(page);
        const kind = header.header().kind.get();
        if (!is_free_list and kind != std.math.maxInt(u16)) {
            header.validateCommon() catch {
                try result.append(allocator, info);
                continue;
            };
            info.kind = kind;
            if (classifyKind(kind)) |cls| {
                info.component = cls.component;
                info.role = cls.role;
            }
            info.used = @intCast(header.allHeadersSize());
        }
        try result.append(allocator, info);
    }
    return result;
}

/// Runs a fixed operational trace through every composed component.
pub fn run(comptime DatabaseT: type, database: *DatabaseT) !void {
    const AreaBinding = Schema.trait("service_areas").Binding(DatabaseT.BackendType);
    const Box = AreaBinding.Proxy.BoundingBox;
    const WorkOrder = struct {
        id: []const u8,
        value: []const u8,
        due_key: []const u8,
        low: [2]f32,
        high: [2]f32,
    };
    const work_orders = [_]WorkOrder{
        .{
            .id = "00000001",
            .value = "open|high|north pump",
            .due_key = "00000001",
            .low = .{ 10, 10 },
            .high = .{ 20, 20 },
        },
        .{
            .id = "00000002",
            .value = "open|medium|west valve",
            .due_key = "00000002",
            .low = .{ 30, 10 },
            .high = .{ 40, 20 },
        },
        .{
            .id = "00000003",
            .value = "open|critical|river sensor",
            .due_key = "00000003",
            .low = .{ 50, 10 },
            .high = .{ 60, 20 },
        },
        .{
            .id = "00000004",
            .value = "assigned|low|school meter",
            .due_key = "00000004",
            .low = .{ 10, 30 },
            .high = .{ 20, 40 },
        },
        .{
            .id = "00000005",
            .value = "open|high|station relay",
            .due_key = "00000005",
            .low = .{ 30, 30 },
            .high = .{ 40, 40 },
        },
    };

    {
        var transaction = try database.begin();
        defer transaction.deinit();
        for (work_orders) |work_order| {
            if (!try transaction.get("orders").insert(work_order.id, work_order.value)) {
                return error.ScenarioInvariantViolation;
            }
            if (!try transaction.get("by_status_due").insert(work_order.due_key, "")) {
                return error.ScenarioInvariantViolation;
            }
            try transaction.get("service_areas").insert(
                Box.initWith(work_order.low, work_order.high),
                work_order.id,
            );
            try transaction.get("dispatch_queue").push(work_order.due_key, "");
        }
        try transaction.get("audit_log").append("created:00000001\ncreated:00000002\ncreated:00000003\ncreated:00000004\ncreated:00000005\n");
        try transaction.get("runbook").append("Inspect pump before dispatch.");
        try transaction.commit();
    }

    {
        var transaction = try database.begin();
        defer transaction.deinit();
        _ = try transaction.get("orders").insert("rollback", "must disappear");
        try transaction.get("audit_log").append("rollback\n");
        try transaction.get("runbook").insert(0, "ROLLBACK: ");
        try transaction.rollback();
    }

    var found = (try database.getConst("orders").find("00000001")).?;
    defer found.deinit();
    const entry = (try found.get()).?;
    if (!std.mem.eql(u8, "open|high|north pump", entry.value)) {
        return error.ScenarioInvariantViolation;
    }
    if ((try database.getConst("orders").find("rollback")) != null) {
        return error.ScenarioInvariantViolation;
    }

    if ((try database.getConst("dispatch_queue").count()) != work_orders.len) {
        return error.ScenarioInvariantViolation;
    }

    var log_bytes: [34]u8 = undefined;
    const audit_log = database.getConst("audit_log");
    if ((try audit_log.readAt(0, &log_bytes)) != 34) {
        return error.ScenarioInvariantViolation;
    }
    if (!std.mem.eql(u8, "created:00000001\ncreated:00000002\n", log_bytes[0..34])) {
        return error.ScenarioInvariantViolation;
    }

    var runbook_bytes: [64]u8 = undefined;
    const runbook = database.getConst("runbook");
    const runbook_len = try runbook.readAt(0, &runbook_bytes);
    if (!std.mem.eql(u8, "Inspect pump before dispatch.", runbook_bytes[0..runbook_len])) {
        return error.ScenarioInvariantViolation;
    }
}

pub fn runMemory(allocator: std.mem.Allocator) !void {
    var database = try MemoryDatabase.init(allocator, .{
        .page_size = 512,
        .cache_frames = 32,
    });
    defer database.deinit();
    try run(MemoryDatabase, &database);
}
