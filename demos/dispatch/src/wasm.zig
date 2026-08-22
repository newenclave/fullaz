const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");
const dispatch = @import("dispatch");

const allocator = std.heap.wasm_allocator;

const Device = fullaz.device.MemoryBlock(u32);
const Log = fullaz.device.MemoryLog(u32);
const Database = fullaz_db.StaticDatabaseWithWal(dispatch.Schema, Device, Log);

pub const panic = std.debug.FullPanic(struct {
    fn handler(_: []const u8, _: ?usize) noreturn {
        @trap();
    }
}.handler);

const page_size: usize = 512;
const options: Database.InitOptions = .{
    .image_id = [_]u8{0x44} ** 16,
    .components = .{
        .orders = .{},
        .by_status_due = .{},
        .service_areas = .{},
        .dispatch_queue = .{},
        .audit_log = .{},
        .runbook = .{},
    },
};

var database: Database = undefined;
var ready = false;
var last_error: []const u8 = "";

var next_due_id: [8]u8 = undefined;
var complete_id: [8]u8 = undefined;
var area_ids: std.ArrayList([8]u8) = .empty;
var order_snapshots: std.ArrayList(dispatch.OrderSnapshot) = .empty;
var page_infos: std.ArrayList(dispatch.PageInfo) = .empty;

fn fail(err: anyerror) u32 {
    last_error = @errorName(err);
    return 0;
}

fn input(ptr: usize, len: usize) []const u8 {
    if (len == 0) {
        return &.{};
    }
    const bytes: [*]const u8 = @ptrFromInt(ptr);
    return bytes[0..len];
}

fn teardown() void {
    if (!ready) {
        return;
    }
    database.deinit();
    ready = false;
}

fn clearBuffers() void {
    area_ids.deinit(allocator);
    area_ids = .empty;
    order_snapshots.deinit(allocator);
    order_snapshots = .empty;
    page_infos.deinit(allocator);
    page_infos = .empty;
}

export fn allocate(len: usize) usize {
    const bytes = allocator.alloc(u8, len) catch return 0;
    return @intFromPtr(bytes.ptr);
}

export fn freeAllocation(ptr: usize, len: usize) void {
    if (len == 0) {
        return;
    }
    const bytes: [*]u8 = @ptrFromInt(ptr);
    allocator.free(bytes[0..len]);
}

/// Starts a fresh, empty database.
export fn format() u32 {
    teardown();
    clearBuffers();
    var device = Device.init(allocator, page_size) catch |err| return fail(err);
    const log = Log.init(allocator) catch |err| {
        device.deinit();
        return fail(err);
    };
    database = Database.format(allocator, device, log, options) catch |err| return fail(err);
    ready = true;
    last_error = "";
    return 1;
}

/// Opens a database from a previously exported image.
export fn importImage(ptr: usize, len: usize) u32 {
    if (len == 0 or len % page_size != 0) {
        last_error = "InvalidImageSize";
        return 0;
    }
    teardown();
    clearBuffers();
    var device = Device.init(allocator, page_size) catch |err| return fail(err);
    device.storage.resize(allocator, len) catch |err| {
        device.deinit();
        return fail(err);
    };
    @memcpy(device.storage.items, input(ptr, len));
    const log = Log.init(allocator) catch |err| {
        device.deinit();
        return fail(err);
    };
    database = Database.open(allocator, device, log, options) catch |err| return fail(err);
    ready = true;
    last_error = "";
    return 1;
}

export fn addOrder(
    id_ptr: usize,
    id_len: usize,
    value_ptr: usize,
    value_len: usize,
    low0: f32,
    low1: f32,
    high0: f32,
    high1: f32,
) u32 {
    if (!ready) {
        last_error = "NotReady";
        return 0;
    }
    if (id_len != 8) {
        last_error = "InvalidId";
        return 0;
    }
    var id: [8]u8 = undefined;
    @memcpy(&id, input(id_ptr, id_len));
    dispatch.addOrder(Database, &database, .{
        .id = id,
        .value = input(value_ptr, value_len),
        .low = .{ low0, low1 },
        .high = .{ high0, high1 },
    }) catch |err| return fail(err);
    last_error = "";
    return 1;
}

export fn nextDue() u32 {
    if (!ready) {
        last_error = "NotReady";
        return 0;
    }
    const due = dispatch.nextDue(Database, &database) catch |err| return fail(err);
    if (due == null) {
        last_error = "Empty";
        return 0;
    }
    next_due_id = due.?;
    last_error = "";
    return 1;
}

export fn nextDuePtr() usize {
    return @intFromPtr(&next_due_id);
}

export fn completeNext() u32 {
    if (!ready) {
        last_error = "NotReady";
        return 0;
    }
    const done = dispatch.completeNext(Database, &database) catch |err| return fail(err);
    if (done == null) {
        last_error = "Empty";
        return 0;
    }
    complete_id = done.?;
    last_error = "";
    return 1;
}

export fn completePtr() usize {
    return @intFromPtr(&complete_id);
}

export fn ordersInArea(low0: f32, low1: f32, high0: f32, high1: f32) u32 {
    if (!ready) {
        last_error = "NotReady";
        return 0;
    }
    area_ids.deinit(allocator);
    area_ids = .empty;
    area_ids = dispatch.ordersInArea(
        Database,
        &database,
        allocator,
        .{ low0, low1 },
        .{ high0, high1 },
    ) catch |err| return fail(err);
    last_error = "";
    return 1;
}

export fn areaIdsPtr() usize {
    return @intFromPtr(area_ids.items.ptr);
}

export fn areaCount() usize {
    return area_ids.items.len;
}

export fn snapshotOrders() u32 {
    if (!ready) {
        last_error = "NotReady";
        return 0;
    }
    order_snapshots.deinit(allocator);
    order_snapshots = .empty;
    order_snapshots = dispatch.snapshotOrders(
        Database,
        &database,
        allocator,
    ) catch |err| return fail(err);
    last_error = "";
    return 1;
}

export fn ordersPtr() usize {
    return @intFromPtr(order_snapshots.items.ptr);
}

export fn ordersCount() usize {
    return order_snapshots.items.len;
}

export fn orderStride() usize {
    return @sizeOf(dispatch.OrderSnapshot);
}

export fn snapshotPages() u32 {
    if (!ready) {
        last_error = "NotReady";
        return 0;
    }
    page_infos.deinit(allocator);
    page_infos = .empty;
    page_infos = dispatch.inspectPages(
        database.deviceBytes(),
        database.diagnostics().page_size,
        &.{},
        allocator,
    ) catch |err| return fail(err);
    last_error = "";
    return 1;
}

export fn pagesPtr() usize {
    return @intFromPtr(page_infos.items.ptr);
}

export fn pagesCount() usize {
    return page_infos.items.len;
}

export fn pageStride() usize {
    return @sizeOf(dispatch.PageInfo);
}

export fn imagePtr() usize {
    if (!ready) {
        return 0;
    }
    return @intFromPtr(database.deviceBytes().ptr);
}

export fn imageLen() usize {
    if (!ready) {
        return 0;
    }
    return database.deviceBytes().len;
}

export fn pageSize() usize {
    if (!ready) {
        return 0;
    }
    return database.diagnostics().page_size;
}

export fn queueCount() u64 {
    if (!ready) {
        return 0;
    }
    return database.getConst("dispatch_queue").count() catch return 0;
}

export fn auditLen() u32 {
    if (!ready) {
        return 0;
    }
    const size = database.getConst("audit_log").size() catch return 0;
    return @intCast(size);
}

export fn lastErrorPtr() usize {
    return @intFromPtr(last_error.ptr);
}

export fn lastErrorLen() usize {
    return last_error.len;
}
