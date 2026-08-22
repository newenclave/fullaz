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
    const order_id = "00000001";
    const order = "open|high|north pump";
    const due_key = "\x00\x00\x00\x00\x00\x00\x00\x01";
    const queue_key = "\x00\x00\x00\x00\x00\x00\x00\x01";

    {
        var transaction = try database.begin();
        defer transaction.deinit();
        if (!try transaction.get("orders").insert(order_id, order)) {
            return error.ScenarioInvariantViolation;
        }
        if (!try transaction.get("by_status_due").insert(due_key, "")) {
            return error.ScenarioInvariantViolation;
        }
        try transaction.get("service_areas").insert(
            Box.initWith(.{ 10, 10 }, .{ 20, 20 }),
            order_id,
        );
        try transaction.get("dispatch_queue").push(queue_key, "");
        try transaction.get("audit_log").append("created:00000001\n");
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

    var found = (try database.getConst("orders").find(order_id)).?;
    defer found.deinit();
    const entry = (try found.get()).?;
    if (!std.mem.eql(u8, order, entry.value)) {
        return error.ScenarioInvariantViolation;
    }
    if ((try database.getConst("orders").find("rollback")) != null) {
        return error.ScenarioInvariantViolation;
    }

    if ((try database.getConst("dispatch_queue").count()) != 1) {
        return error.ScenarioInvariantViolation;
    }

    var log_bytes: [32]u8 = undefined;
    const audit_log = database.getConst("audit_log");
    if ((try audit_log.readAt(0, &log_bytes)) != 17) {
        return error.ScenarioInvariantViolation;
    }
    if (!std.mem.eql(u8, "created:00000001\n", log_bytes[0..17])) {
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
