const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");
const lab = @import("db_lab");

const allocator = std.heap.wasm_allocator;
const page_size = 1024;
const Device32 = fullaz.device.MemoryBlock(u32);
const Log32 = fullaz.device.MemoryLog(u32);
const MemoryDatabase = fullaz_db.MemoryDatabase(lab.Schema);
const StaticDatabase = fullaz_db.StaticDatabaseWithWal(lab.Schema, Device32, Log32);
const DynamicDatabase = fullaz_db.DynamicSchemaDatabaseWithWal(lab.Schema, Device32, Log32);
// Browser WASM is wasm32, so both namespaces use u32 here. They remain
// separate address spaces: the VPM still maps a stable VID to a physical PID.
const VirtualDatabase = fullaz_db.VirtualStaticDatabaseWithWal(lab.Schema, Device32, Log32);

const Database = union(enum) {
    memory: MemoryDatabase,
    static: StaticDatabase,
    dynamic: DynamicDatabase,
    virtual: VirtualDatabase,
};

const GcStatus = enum(u32) {
    unsupported,
    idle,
    marking,
    ready_to_sweep,
    complete,
};

pub const panic = std.debug.FullPanic(struct {
    fn handler(_: []const u8, _: ?usize) noreturn {
        @trap();
    }
}.handler);

var database: ?Database = null;
var rows: std.ArrayList(lab.Row) = .empty;
var last_error: []const u8 = "";
var gc_status: GcStatus = .unsupported;
var gc_page_count: usize = 0;
var gc_free_page_count: usize = 0;
var gc_free_pages_before_sweep: usize = 0;
var gc_reclaimed_page_count: usize = 0;
var gc_step_count: usize = 0;
var generation_target: usize = 0;
var generation_completed: usize = 0;

const static_options: StaticDatabase.InitOptions = .{
    .image_id = [_]u8{0x53} ** 16,
    .cache_frames = 32,
    .components = .{ .catalog = .{ .owner_0 = .{} } },
};
const dynamic_options: DynamicDatabase.InitOptions = .{
    .image_id = [_]u8{0x44} ** 16,
    .cache_frames = 32,
    .components = .{ .catalog = .{ .owner_0 = .{} } },
};
const virtual_options: VirtualDatabase.InitOptions = .{
    .image_id = [_]u8{0x56} ** 16,
    .cache_frames = 32,
    .components = .{ .catalog = .{ .owner_0 = .{} } },
};

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
    if (database) |*current| {
        switch (current.*) {
            inline else => |*value| value.deinit(),
        }
        database = null;
    }
    rows.deinit(allocator);
    rows = .empty;
    resetGcStats(false);
    generation_target = 0;
    generation_completed = 0;
}

fn resetGcStats(supported: bool) void {
    gc_status = if (supported) .idle else .unsupported;
    gc_page_count = 0;
    gc_free_page_count = 0;
    gc_free_pages_before_sweep = 0;
    gc_reclaimed_page_count = 0;
    gc_step_count = 0;
}

fn resetGcStatsForCurrentDatabase() void {
    const current = &(database orelse {
        resetGcStats(false);
        return;
    });
    resetGcStats(switch (current.*) {
        .dynamic => true,
        else => false,
    });
}

fn makeDevice(comptime BlockIdT: type, bytes: []const u8) !fullaz.device.MemoryBlock(BlockIdT) {
    var device = try fullaz.device.MemoryBlock(BlockIdT).init(allocator, page_size);
    errdefer device.deinit();
    try device.storage.resize(allocator, bytes.len);
    @memcpy(device.storage.items, bytes);
    return device;
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

/// `kind`: 0 memory, 1 static WAL, 2 virtual WAL, 3 dynamic WAL with GC.
export fn format(kind: u32) u32 {
    teardown();
    switch (kind) {
        0 => database = .{ .memory = MemoryDatabase.init(allocator, .{
            .page_size = page_size,
            .cache_frames = 32,
            .components = .{ .catalog = .{ .owner_0 = .{} } },
        }) catch |err| return fail(err) },
        1 => {
            var device = Device32.init(allocator, page_size) catch |err| return fail(err);
            const log = Log32.init(allocator) catch |err| {
                device.deinit();
                return fail(err);
            };
            database = .{ .static = StaticDatabase.format(allocator, device, log, static_options) catch |err| return fail(err) };
        },
        3 => {
            var device = Device32.init(allocator, page_size) catch |err| return fail(err);
            const log = Log32.init(allocator) catch |err| {
                device.deinit();
                return fail(err);
            };
            database = .{ .dynamic = DynamicDatabase.format(allocator, device, log, dynamic_options) catch |err| return fail(err) };
        },
        2 => {
            var device = Device32.init(allocator, page_size) catch |err| return fail(err);
            const log = Log32.init(allocator) catch |err| {
                device.deinit();
                return fail(err);
            };
            database = .{ .virtual = VirtualDatabase.format(allocator, device, log, virtual_options) catch |err| return fail(err) };
        },
        else => {
            last_error = "InvalidEngine";
            return 0;
        },
    }
    resetGcStats(kind == 3);
    last_error = "";
    return 1;
}

/// Imports static, dynamic, or virtual images. Memory deliberately has no image
/// format to make its lack of persistence visible in the lab.
export fn importImage(kind: u32, ptr: usize, len: usize) u32 {
    if (kind == 0 or len == 0 or len % page_size != 0) {
        last_error = "InvalidImage";
        return 0;
    }
    teardown();
    const bytes = input(ptr, len);
    switch (kind) {
        1 => {
            var device = makeDevice(u32, bytes) catch |err| return fail(err);
            const log = Log32.init(allocator) catch |err| {
                device.deinit();
                return fail(err);
            };
            database = .{ .static = StaticDatabase.open(allocator, device, log, static_options) catch |err| return fail(err) };
        },
        3 => {
            var device = makeDevice(u32, bytes) catch |err| return fail(err);
            const log = Log32.init(allocator) catch |err| {
                device.deinit();
                return fail(err);
            };
            database = .{ .dynamic = DynamicDatabase.open(allocator, device, log, dynamic_options) catch |err| return fail(err) };
        },
        2 => {
            var device = makeDevice(u32, bytes) catch |err| return fail(err);
            const log = Log32.init(allocator) catch |err| {
                device.deinit();
                return fail(err);
            };
            database = .{ .virtual = VirtualDatabase.open(allocator, device, log, virtual_options) catch |err| return fail(err) };
        },
        else => {
            last_error = "InvalidEngine";
            return 0;
        },
    }
    resetGcStats(kind == 3);
    last_error = "";
    return 1;
}

fn mutate(comptime action: anytype, first: []const u8, second: []const u8, third: []const u8) u32 {
    const current = &(database orelse {
        last_error = "NotReady";
        return 0;
    });
    switch (current.*) {
        inline else => |*value| action(value, first, second, third) catch |err| return fail(err),
    }
    resetGcStatsForCurrentDatabase();
    last_error = "";
    return 1;
}

fn createTableAction(value: anytype, table: []const u8, _: []const u8, _: []const u8) !void {
    return lab.createTable(value, table);
}

fn putAction(value: anytype, table: []const u8, key: []const u8, item: []const u8) !void {
    return lab.put(value, table, key, item);
}

fn removeAction(value: anytype, table: []const u8, key: []const u8, _: []const u8) !void {
    if (!try lab.remove(value, table, key)) {
        return error.ValueNotFound;
    }
}

fn deleteTableAction(value: anytype, table: []const u8, _: []const u8, _: []const u8) !void {
    if (!try lab.deleteTable(value, table)) {
        return error.TableNotFound;
    }
}

export fn createTable(ptr: usize, len: usize) u32 {
    return mutate(createTableAction, input(ptr, len), &.{}, &.{});
}

export fn put(table_ptr: usize, table_len: usize, key_ptr: usize, key_len: usize, value_ptr: usize, value_len: usize) u32 {
    return mutate(
        putAction,
        input(table_ptr, table_len),
        input(key_ptr, key_len),
        input(value_ptr, value_len),
    );
}

export fn remove(table_ptr: usize, table_len: usize, key_ptr: usize, key_len: usize) u32 {
    return mutate(removeAction, input(table_ptr, table_len), input(key_ptr, key_len), &.{});
}

export fn deleteTable(table_ptr: usize, table_len: usize) u32 {
    return mutate(deleteTableAction, input(table_ptr, table_len), &.{}, &.{});
}

export fn generateExamples() u32 {
    return generateExamplesWithCount(@intCast(lab.default_planet_count));
}

export fn generateExamplesWithCount(count: u32) u32 {
    const planet_count: usize = std.math.cast(usize, count) orelse return fail(error.InvalidExampleCount);
    if (planet_count < lab.minimum_planet_count or planet_count > lab.maximum_planet_count) {
        return fail(error.InvalidExampleCount);
    }
    const current = &(database orelse {
        last_error = "NotReady";
        return 0;
    });
    generation_target = planet_count;
    generation_completed = 0;
    switch (current.*) {
        inline else => |*value| lab.generateExamplesWithCount(
            value,
            allocator,
            planet_count,
            &generation_completed,
        ) catch |err| return fail(err),
    }
    resetGcStatsForCurrentDatabase();
    last_error = "";
    return 1;
}

export fn minimumPlanetCount() usize {
    return lab.minimum_planet_count;
}

export fn defaultPlanetCount() usize {
    return lab.default_planet_count;
}

export fn maximumPlanetCount() usize {
    return lab.maximum_planet_count;
}

export fn generatedPlanetTarget() usize {
    return generation_target;
}

export fn generatedPlanetCount() usize {
    return generation_completed;
}

fn requireDynamicDatabase() !*DynamicDatabase {
    const current = &(database orelse return error.NotReady);
    return switch (current.*) {
        .dynamic => |*value| value,
        else => error.GarbageCollectionUnsupported,
    };
}

fn countFreePages(value: *DynamicDatabase) !usize {
    const cache = value.cache();
    const page_count = cache.pageCount();
    var count: usize = 0;
    var index: usize = 0;
    while (index < page_count) : (index += 1) {
        const page_id: u32 = std.math.cast(u32, index) orelse return error.PageIdTooLarge;
        if (try cache.isFree(page_id)) {
            count += 1;
        }
    }
    return count;
}

fn captureGcStats(value: *DynamicDatabase) !void {
    gc_page_count = value.cache().pageCount();
    gc_free_page_count = try countFreePages(value);
}

/// Completes prepare and mark work, then stops before the first sweep step.
export fn markGarbageCollection() u32 {
    const value = requireDynamicDatabase() catch |err| return fail(err);
    const phase = value.garbageCollectionPhase() catch |err| return fail(err);
    if (phase == .idle) {
        resetGcStats(true);
        value.startGarbageCollection() catch |err| return fail(err);
    }

    gc_status = .marking;
    while (true) {
        const active_phase = value.garbageCollectionPhase() catch |err| return fail(err);
        switch (active_phase) {
            .preparing, .marking => {
                _ = value.stepGarbageCollection(32) catch |err| return fail(err);
                gc_step_count += 1;
            },
            .sweeping => {
                captureGcStats(value) catch |err| return fail(err);
                gc_free_pages_before_sweep = gc_free_page_count;
                gc_status = .ready_to_sweep;
                last_error = "";
                return 1;
            },
            .idle => {
                return fail(error.GarbageCollectionStopped);
            },
        }
    }
}

/// Reclaims every page that the completed mark phase did not reach.
export fn sweepGarbageCollection() u32 {
    const value = requireDynamicDatabase() catch |err| return fail(err);
    const phase = value.garbageCollectionPhase() catch |err| return fail(err);
    if (phase != .sweeping) {
        return fail(error.GarbageCollectionMarkRequired);
    }

    while (true) {
        const status = value.stepGarbageCollection(32) catch |err| return fail(err);
        gc_step_count += 1;
        if (status == .complete) {
            break;
        }
    }
    captureGcStats(value) catch |err| return fail(err);
    gc_reclaimed_page_count = if (gc_free_page_count >= gc_free_pages_before_sweep)
        gc_free_page_count - gc_free_pages_before_sweep
    else
        0;
    gc_status = .complete;
    last_error = "";
    return 1;
}

export fn gcStatus() u32 {
    return @intFromEnum(gc_status);
}

export fn gcPageCount() usize {
    return gc_page_count;
}

export fn gcFreePageCount() usize {
    return gc_free_page_count;
}

export fn gcReclaimedPageCount() usize {
    return gc_reclaimed_page_count;
}

export fn gcStepCount() usize {
    return gc_step_count;
}

export fn snapshotRows() u32 {
    const current = &(database orelse {
        last_error = "NotReady";
        return 0;
    });
    rows.deinit(allocator);
    rows = .empty;
    switch (current.*) {
        inline else => |*value| rows = lab.snapshot(value, allocator) catch |err| return fail(err),
    }
    last_error = "";
    return 1;
}

export fn rowsPtr() usize {
    return @intFromPtr(rows.items.ptr);
}

export fn rowsCount() usize {
    return rows.items.len;
}

export fn rowStride() usize {
    return @sizeOf(lab.Row);
}

export fn imagePtr() usize {
    const current = &(database orelse return 0);
    return switch (current.*) {
        inline else => |*value| @intFromPtr(value.deviceBytes().ptr),
    };
}

export fn imageLen() usize {
    const current = &(database orelse return 0);
    return switch (current.*) {
        inline else => |*value| value.deviceBytes().len,
    };
}

export fn currentEngine() u32 {
    const current = &(database orelse return 3);
    return switch (current.*) {
        .memory => 0,
        .static => 1,
        .virtual => 2,
        .dynamic => 3,
    };
}

export fn lastErrorPtr() usize {
    return @intFromPtr(last_error.ptr);
}

export fn lastErrorLen() usize {
    return last_error.len;
}
