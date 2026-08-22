const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

fn compare(_: void, left: []const u8, right: []const u8) fullaz.core.algorithm.Order {
    return switch (std.mem.order(u8, left, right)) {
        .lt => .lt,
        .eq => .eq,
        .gt => .gt,
    };
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
        .Coord = i32,
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

/// Runs a fixed operational trace through every composed component.
pub fn run(comptime DatabaseT: type, database: *DatabaseT) !void {
    const AreaBinding = Schema.trait("service_areas").Binding(DatabaseT.BackendType);
    const Box = AreaBinding.Proxy.BoundingBox;
    const WorkOrder = struct {
        id: []const u8,
        value: []const u8,
        due_key: []const u8,
        low: [2]i32,
        high: [2]i32,
    };
    const work_orders = [_]WorkOrder{
        .{ .id = "00000001", .value = "open|high|north pump", .due_key = "00000001", .low = .{ 10, 10 }, .high = .{ 20, 20 } },
        .{ .id = "00000002", .value = "open|medium|west valve", .due_key = "00000002", .low = .{ 30, 10 }, .high = .{ 40, 20 } },
        .{ .id = "00000003", .value = "open|critical|river sensor", .due_key = "00000003", .low = .{ 50, 10 }, .high = .{ 60, 20 } },
        .{ .id = "00000004", .value = "assigned|low|school meter", .due_key = "00000004", .low = .{ 10, 30 }, .high = .{ 20, 40 } },
        .{ .id = "00000005", .value = "open|high|station relay", .due_key = "00000005", .low = .{ 30, 30 }, .high = .{ 40, 40 } },
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
