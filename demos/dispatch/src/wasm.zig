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
        .simulation = .{},
        .orders = .{},
        .service_areas = .{},
        .pending = .{},
        .suspended = .{},
        .history = .{},
    },
};

var database: Database = undefined;
var ready = false;
var last_error: []const u8 = "";

var simulation_snapshot: dispatch.SimulationSnapshot = std.mem.zeroes(dispatch.SimulationSnapshot);
var area_ids: std.ArrayList([8]u8) = .empty;
var order_snapshots: std.ArrayList(dispatch.OrderSnapshot) = .empty;
var pending_ids: std.ArrayList([8]u8) = .empty;
var suspended_ids: std.ArrayList([8]u8) = .empty;
var history_snapshots: std.ArrayList(dispatch.HistorySnapshot) = .empty;
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

fn clearBuffers() void {
    simulation_snapshot = std.mem.zeroes(dispatch.SimulationSnapshot);
    area_ids.deinit(allocator);
    area_ids = .empty;
    order_snapshots.deinit(allocator);
    order_snapshots = .empty;
    pending_ids.deinit(allocator);
    pending_ids = .empty;
    suspended_ids.deinit(allocator);
    suspended_ids = .empty;
    history_snapshots.deinit(allocator);
    history_snapshots = .empty;
    page_infos.deinit(allocator);
    page_infos = .empty;
}

fn teardown() void {
    clearBuffers();
    if (!ready) {
        return;
    }
    database.deinit();
    ready = false;
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
    var device = Device.init(allocator, page_size) catch |err| return fail(err);
    var log = Log.init(allocator) catch |err| {
        device.deinit();
        return fail(err);
    };
    database = Database.format(allocator, device, log, options) catch |err| {
        log.deinit();
        device.deinit();
        return fail(err);
    };
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
    var device = Device.init(allocator, page_size) catch |err| return fail(err);
    device.storage.resize(allocator, len) catch |err| {
        device.deinit();
        return fail(err);
    };
    @memcpy(device.storage.items, input(ptr, len));
    var log = Log.init(allocator) catch |err| {
        device.deinit();
        return fail(err);
    };
    const open = Database.open(allocator, device, log, options) catch |err| {
        log.deinit();
        device.deinit();
        return fail(err);
    };
    database = open;
    ready = true;
    last_error = "";
    return 1;
}

export fn initializeSimulation(latitude: f32, longitude: f32) u32 {
    if (!ready) {
        last_error = "NotReady";
        return 0;
    }
    dispatch.initializeSimulation(Database, &database, .{
        .latitude = latitude,
        .longitude = longitude,
    }) catch |err| return fail(err);
    last_error = "";
    return 1;
}

export fn addOrder(latitude: f32, longitude: f32, description_ptr: usize, description_len: usize) u32 {
    if (!ready) {
        last_error = "NotReady";
        return 0;
    }
    _ = dispatch.addOrder(Database, &database, .{
        .latitude = latitude,
        .longitude = longitude,
    }, input(description_ptr, description_len)) catch |err| return fail(err);
    last_error = "";
    return 1;
}

export fn addEmergency(latitude: f32, longitude: f32, description_ptr: usize, description_len: usize) u32 {
    if (!ready) {
        last_error = "NotReady";
        return 0;
    }
    _ = dispatch.addEmergency(Database, &database, .{
        .latitude = latitude,
        .longitude = longitude,
    }, input(description_ptr, description_len)) catch |err| return fail(err);
    last_error = "";
    return 1;
}

export fn stepSimulation() u32 {
    if (!ready) {
        last_error = "NotReady";
        return 0;
    }
    dispatch.stepSimulation(Database, &database) catch |err| return fail(err);
    last_error = "";
    return 1;
}

export fn setAutoOrders(enabled: u32) u32 {
    if (!ready) {
        last_error = "NotReady";
        return 0;
    }
    dispatch.setAutoOrders(Database, &database, enabled != 0) catch |err| return fail(err);
    last_error = "";
    return 1;
}

export fn snapshotSimulation() u32 {
    if (!ready) {
        last_error = "NotReady";
        return 0;
    }
    simulation_snapshot = dispatch.snapshotSimulation(Database, &database) catch |err| return fail(err);
    last_error = "";
    return 1;
}

export fn simulationPtr() usize {
    return @intFromPtr(&simulation_snapshot);
}

export fn simulationStride() usize {
    return @sizeOf(dispatch.SimulationSnapshot);
}

export fn snapshotOrders() u32 {
    if (!ready) {
        last_error = "NotReady";
        return 0;
    }
    order_snapshots.deinit(allocator);
    order_snapshots = .empty;
    order_snapshots = dispatch.snapshotOrders(Database, &database, allocator) catch |err| return fail(err);
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

export fn snapshotPending() u32 {
    if (!ready) {
        last_error = "NotReady";
        return 0;
    }
    pending_ids.deinit(allocator);
    pending_ids = .empty;
    pending_ids = dispatch.snapshotSequence(Database, &database, "pending", allocator) catch |err| return fail(err);
    last_error = "";
    return 1;
}

export fn pendingPtr() usize {
    return @intFromPtr(pending_ids.items.ptr);
}

export fn pendingCount() usize {
    return pending_ids.items.len;
}

export fn snapshotSuspended() u32 {
    if (!ready) {
        last_error = "NotReady";
        return 0;
    }
    suspended_ids.deinit(allocator);
    suspended_ids = .empty;
    suspended_ids = dispatch.snapshotSequence(Database, &database, "suspended", allocator) catch |err| return fail(err);
    last_error = "";
    return 1;
}

export fn suspendedPtr() usize {
    return @intFromPtr(suspended_ids.items.ptr);
}

export fn suspendedCount() usize {
    return suspended_ids.items.len;
}

export fn snapshotHistory() u32 {
    if (!ready) {
        last_error = "NotReady";
        return 0;
    }
    history_snapshots.deinit(allocator);
    history_snapshots = .empty;
    history_snapshots = dispatch.snapshotHistory(Database, &database, allocator) catch |err| return fail(err);
    last_error = "";
    return 1;
}

export fn historyPtr() usize {
    return @intFromPtr(history_snapshots.items.ptr);
}

export fn historyCount() usize {
    return history_snapshots.items.len;
}

export fn historyStride() usize {
    return @sizeOf(dispatch.HistorySnapshot);
}

export fn ordersInArea(low_latitude: f32, low_longitude: f32, high_latitude: f32, high_longitude: f32) u32 {
    if (!ready) {
        last_error = "NotReady";
        return 0;
    }
    area_ids.deinit(allocator);
    area_ids = .empty;
    area_ids = dispatch.ordersInArea(Database, &database, allocator, .{
        .latitude = low_latitude,
        .longitude = low_longitude,
    }, .{
        .latitude = high_latitude,
        .longitude = high_longitude,
    }) catch |err| return fail(err);
    last_error = "";
    return 1;
}

export fn areaIdsPtr() usize {
    return @intFromPtr(area_ids.items.ptr);
}

export fn areaCount() usize {
    return area_ids.items.len;
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

export fn lastErrorPtr() usize {
    return @intFromPtr(last_error.ptr);
}

export fn lastErrorLen() usize {
    return last_error.len;
}
