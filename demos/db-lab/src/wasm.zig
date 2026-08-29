const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");
const lab = @import("db_lab");

const allocator = std.heap.wasm_allocator;
const page_size = 512;
const Device32 = fullaz.device.MemoryBlock(u32);
const Log32 = fullaz.device.MemoryLog(u32);
const MemoryDatabase = fullaz_db.MemoryDatabase(lab.Schema);
const StaticDatabase = fullaz_db.StaticDatabaseWithWal(lab.Schema, Device32, Log32);
// Browser WASM is wasm32, so both namespaces use u32 here. They remain
// separate address spaces: the VPM still maps a stable VID to a physical PID.
const VirtualDatabase = fullaz_db.VirtualStaticDatabaseWithWal(lab.Schema, Device32, Log32);

const Database = union(enum) {
    memory: MemoryDatabase,
    static: StaticDatabase,
    virtual: VirtualDatabase,
};

pub const panic = std.debug.FullPanic(struct {
    fn handler(_: []const u8, _: ?usize) noreturn {
        @trap();
    }
}.handler);

var database: ?Database = null;
var rows: std.ArrayList(lab.Row) = .empty;
var last_error: []const u8 = "";

const static_options: StaticDatabase.InitOptions = .{
    .image_id = [_]u8{0x53} ** 16,
    .components = .{ .tables = .{}, .values = .{} },
};
const virtual_options: VirtualDatabase.InitOptions = .{
    .image_id = [_]u8{0x56} ** 16,
    .components = .{ .tables = .{}, .values = .{} },
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

/// `kind`: 0 memory, 1 static WAL, 2 virtual WAL.
export fn format(kind: u32) u32 {
    teardown();
    switch (kind) {
        0 => database = .{ .memory = MemoryDatabase.init(allocator, .{
            .page_size = page_size,
            .cache_frames = 32,
        }) catch |err| return fail(err) },
        1 => {
            var device = Device32.init(allocator, page_size) catch |err| return fail(err);
            const log = Log32.init(allocator) catch |err| {
                device.deinit();
                return fail(err);
            };
            database = .{ .static = StaticDatabase.format(allocator, device, log, static_options) catch |err| return fail(err) };
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
    last_error = "";
    return 1;
}

/// Imports static or virtual images. Memory backend deliberately has no image
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
    };
}

export fn lastErrorPtr() usize {
    return @intFromPtr(last_error.ptr);
}

export fn lastErrorLen() usize {
    return last_error.len;
}
