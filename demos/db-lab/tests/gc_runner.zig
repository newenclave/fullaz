const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");
const lab = @import("db_lab");

const GcRunner = lab.GcRunner;
const Device = fullaz.device.MemoryBlock(u32);
const Log = fullaz.device.MemoryLog(u32);
const StaticDatabase = fullaz_db.StaticDatabaseWithWal(lab.Schema, Device, Log);
const VirtualDatabase = fullaz_db.VirtualStaticDatabaseWithWal(lab.Schema, Device, Log);
const DynamicDatabase = fullaz_db.DynamicSchemaDatabaseWithWal(lab.Schema, Device, Log);

const static_options: StaticDatabase.InitOptions = .{
    .image_id = [_]u8{0x71} ** 16,
    .cache_frames = 32,
    .components = .{ .catalog = .{ .owner_0 = .{} } },
};
const virtual_options: VirtualDatabase.InitOptions = .{
    .image_id = [_]u8{0x72} ** 16,
    .cache_frames = 32,
    .components = .{ .catalog = .{ .owner_0 = .{} } },
};
const dynamic_options: DynamicDatabase.InitOptions = .{
    .image_id = [_]u8{0x73} ** 16,
    .cache_frames = 32,
    .components = .{ .catalog = .{ .owner_0 = .{} } },
};

const FakeDatabase = struct {
    const Error = error{
        CycleInactive,
        CycleActive,
        StartFailed,
        StepFailed,
        CancelFailed,
    };

    phase: fullaz.gc.Phase = .idle,
    mark_steps_remaining: usize = 2,
    sweep_steps_remaining: usize = 2,
    start_calls: usize = 0,
    step_calls: usize = 0,
    cancel_calls: usize = 0,
    fail_start: bool = false,
    fail_step: bool = false,
    fail_cancel: bool = false,

    pub fn startGarbageCollection(self: *FakeDatabase) Error!void {
        if (self.fail_start) {
            return error.StartFailed;
        }
        if (self.phase != .idle) {
            return error.CycleActive;
        }
        self.start_calls += 1;
        self.phase = .preparing;
    }

    pub fn stepGarbageCollection(
        self: *FakeDatabase,
        _: usize,
    ) Error!fullaz.gc.StepStatus {
        if (self.fail_step) {
            return error.StepFailed;
        }
        if (self.phase == .idle) {
            return error.CycleInactive;
        }
        self.step_calls += 1;

        switch (self.phase) {
            .preparing => self.phase = .marking,
            .marking => {
                if (self.mark_steps_remaining > 1) {
                    self.mark_steps_remaining -= 1;
                } else {
                    self.mark_steps_remaining = 0;
                    self.phase = .sweeping;
                }
            },
            .sweeping => {
                if (self.sweep_steps_remaining > 1) {
                    self.sweep_steps_remaining -= 1;
                } else {
                    self.sweep_steps_remaining = 0;
                    self.phase = .idle;
                    return .complete;
                }
            },
            .idle => unreachable,
        }
        return .in_progress;
    }

    pub fn garbageCollectionPhase(self: *FakeDatabase) Error!fullaz.gc.Phase {
        return self.phase;
    }

    pub fn cancelGarbageCollection(self: *FakeDatabase) Error!void {
        if (self.fail_cancel) {
            return error.CancelFailed;
        }
        if (self.phase == .idle) {
            return error.CycleInactive;
        }
        self.cancel_calls += 1;
        self.phase = .idle;
    }
};

const EventLog = struct {
    kinds: [32]GcRunner.EventKind = undefined,
    len: usize = 0,

    fn record(context: ?*anyopaque, event: *const GcRunner.Event) void {
        const self: *EventLog = @ptrCast(@alignCast(context.?));
        self.kinds[self.len] = event.kind;
        self.len += 1;
    }
};

test "db-lab GC runner performs one committed mutation per pump and pauses before sweep" {
    var runner = GcRunner.init();
    defer runner.deinit();
    var database: FakeDatabase = .{};
    var first_log: EventLog = .{};
    var second_log: EventLog = .{};
    _ = try runner.subscribe(EventLog.record, &first_log);
    _ = try runner.subscribe(EventLog.record, &second_log);

    try runner.requestMark(8);
    try std.testing.expect(runner.hasPendingWork());
    try std.testing.expectEqual(@as(usize, 0), database.start_calls);

    try std.testing.expect(try runner.pump(&database));
    try std.testing.expectEqual(@as(usize, 1), database.start_calls);
    try std.testing.expectEqual(@as(usize, 0), database.step_calls);

    while (runner.hasPendingWork()) {
        const calls_before = database.step_calls;
        try std.testing.expect(try runner.pump(&database));
        try std.testing.expect(database.step_calls <= calls_before + 1);
    }

    try std.testing.expectEqual(GcRunner.State.ready_to_sweep, runner.state());
    try std.testing.expectEqual(fullaz.gc.Phase.sweeping, database.phase);
    try std.testing.expectEqual(@as(usize, 2), database.sweep_steps_remaining);
    try std.testing.expectEqual(first_log.len, second_log.len);
    try std.testing.expectEqual(
        GcRunner.EventKind.ready_to_sweep,
        first_log.kinds[first_log.len - 1],
    );

    try runner.requestSweep(8);
    while (runner.hasPendingWork()) {
        try std.testing.expect(try runner.pump(&database));
    }
    try std.testing.expectEqual(GcRunner.State.complete, runner.state());
    try std.testing.expectEqual(fullaz.gc.Phase.idle, database.phase);
    try std.testing.expectEqual(
        GcRunner.EventKind.completed,
        first_log.kinds[first_log.len - 1],
    );
}

test "db-lab GC runner cancels queued startup without touching the database" {
    var runner = GcRunner.init();
    defer runner.deinit();
    var database: FakeDatabase = .{};

    try runner.requestMark(1);
    runner.requestCancel();

    try std.testing.expectEqual(GcRunner.State.idle, runner.state());
    try std.testing.expect(!runner.hasPendingWork());
    try std.testing.expect(!(try runner.pump(&database)));
    try std.testing.expectEqual(@as(usize, 0), database.start_calls);
    try std.testing.expectEqual(@as(usize, 0), database.cancel_calls);
}

test "db-lab GC runner cancels an active durable cycle in a later pump" {
    var runner = GcRunner.init();
    defer runner.deinit();
    var database: FakeDatabase = .{};

    try runner.requestMark(32);
    try std.testing.expect(try runner.pump(&database));
    runner.requestCancel();

    try std.testing.expectEqual(GcRunner.State.cancelling, runner.state());
    try std.testing.expectEqual(@as(usize, 0), database.cancel_calls);
    try std.testing.expect(try runner.pump(&database));
    try std.testing.expectEqual(@as(usize, 1), database.cancel_calls);
    try std.testing.expectEqual(GcRunner.State.idle, runner.state());

    runner.requestCancel();
    try std.testing.expect(!runner.hasPendingWork());
}

test "db-lab GC runner restores durable phases without scheduling work" {
    var runner = GcRunner.init();
    defer runner.deinit();

    runner.restore(.marking);
    try std.testing.expectEqual(GcRunner.State.marking, runner.state());
    try std.testing.expect(runner.blocksDatabaseReplacement());
    try std.testing.expect(!runner.hasPendingWork());

    runner.restore(.sweeping);
    try std.testing.expectEqual(GcRunner.State.ready_to_sweep, runner.state());
    try std.testing.expect(runner.blocksDatabaseReplacement());
    try std.testing.expect(!runner.hasPendingWork());

    runner.restore(.idle);
    try std.testing.expectEqual(GcRunner.State.idle, runner.state());
    try std.testing.expect(!runner.blocksDatabaseReplacement());
}

test "db-lab GC runner stops automatic work after a step error" {
    var runner = GcRunner.init();
    defer runner.deinit();
    var database: FakeDatabase = .{};

    try runner.requestMark(8);
    try std.testing.expect(try runner.pump(&database));
    database.fail_step = true;
    try std.testing.expectError(error.StepFailed, runner.pump(&database));

    try std.testing.expectEqual(GcRunner.State.failed, runner.state());
    try std.testing.expect(runner.blocksDatabaseReplacement());
    try std.testing.expect(!runner.hasPendingWork());

    database.fail_step = false;
    runner.requestCancel();
    try std.testing.expect(try runner.pump(&database));
    try std.testing.expectEqual(GcRunner.State.idle, runner.state());
}

test "db-lab GC runner validates budgets and rejects duplicate work" {
    var runner = GcRunner.init();
    defer runner.deinit();

    try std.testing.expectError(error.InvalidPageBudget, runner.requestMark(0));
    try std.testing.expectError(error.InvalidPageBudget, runner.requestMark(2));
    try runner.requestMark(8);
    try std.testing.expectError(error.WorkPending, runner.requestMark(8));
    try std.testing.expectError(error.WorkPending, runner.requestSweep(8));
}

fn makeDevice(bytes: []const u8) !Device {
    var device = try Device.init(std.testing.allocator, 1024);
    errdefer device.deinit();
    try device.storage.resize(std.testing.allocator, bytes.len);
    @memcpy(device.storage.items, bytes);
    return device;
}

fn formatDatabase(comptime Database: type, options: Database.InitOptions) !Database {
    return Database.format(
        std.testing.allocator,
        try Device.init(std.testing.allocator, 1024),
        try Log.init(std.testing.allocator),
        options,
    );
}

fn openDatabase(
    comptime Database: type,
    image: []const u8,
    options: Database.InitOptions,
) !Database {
    return Database.open(
        std.testing.allocator,
        try makeDevice(image),
        try Log.init(std.testing.allocator),
        options,
    );
}

fn countFreePages(database: anytype) !usize {
    const cache = database.cache();
    const page_count = cache.pageCount();
    var count: usize = 0;
    for (0..page_count) |index| {
        const page_id: u32 = std.math.cast(u32, index) orelse return error.PageIdTooLarge;
        if (try cache.isFree(page_id)) {
            count += 1;
        }
    }
    return count;
}

fn prepareDisconnectedTable(database: anytype) !void {
    var committed_planets: usize = 0;
    try lab.generateExamplesWithCount(
        database,
        std.testing.allocator,
        64,
        &committed_planets,
    );
    try std.testing.expectEqual(@as(usize, 64), committed_planets);
    try std.testing.expect(try lab.deleteTable(database, "planets"));
    try expectRetainedRows(database);
}

fn expectRetainedRows(database: anytype) !void {
    var rows = try lab.snapshot(database, std.testing.allocator);
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 5), rows.items.len);
}

fn pumpPending(runner: *GcRunner, database: anytype) !void {
    var pump_count: usize = 0;
    while (runner.hasPendingWork()) : (pump_count += 1) {
        try std.testing.expect(pump_count < 10_000);
        try std.testing.expect(try runner.pump(database));
    }
}

fn runMark(runner: *GcRunner, database: anytype) !void {
    try runner.requestMark(8);
    try pumpPending(runner, database);
    try std.testing.expectEqual(GcRunner.State.ready_to_sweep, runner.state());
    try std.testing.expectEqual(fullaz.gc.Phase.sweeping, try database.garbageCollectionPhase());
}

fn runSweep(runner: *GcRunner, database: anytype) !void {
    try runner.requestSweep(8);
    try pumpPending(runner, database);
    try std.testing.expectEqual(GcRunner.State.complete, runner.state());
    try std.testing.expectEqual(fullaz.gc.Phase.idle, try database.garbageCollectionPhase());
}

fn exerciseCompletion(comptime Database: type, options: Database.InitOptions) !void {
    var database = try formatDatabase(Database, options);
    defer database.deinit();
    try prepareDisconnectedTable(&database);

    var runner = GcRunner.init();
    defer runner.deinit();
    try runMark(&runner, &database);
    try expectRetainedRows(&database);
    const free_pages_before_sweep = try countFreePages(&database);

    try runSweep(&runner, &database);
    try std.testing.expect((try countFreePages(&database)) > free_pages_before_sweep);
    try expectRetainedRows(&database);
    try lab.createTable(&database, "after-gc");
}

fn exerciseCancellation(comptime Database: type, options: Database.InitOptions) !void {
    var database = try formatDatabase(Database, options);
    defer database.deinit();
    try prepareDisconnectedTable(&database);

    var runner = GcRunner.init();
    defer runner.deinit();
    try runner.requestMark(1);
    try std.testing.expect(try runner.pump(&database));
    try std.testing.expect(try runner.pump(&database));

    runner.requestCancel();
    try std.testing.expectEqual(GcRunner.State.cancelling, runner.state());
    try pumpPending(&runner, &database);
    try std.testing.expectEqual(GcRunner.State.idle, runner.state());
    try std.testing.expectEqual(fullaz.gc.Phase.idle, try database.garbageCollectionPhase());
    try expectRetainedRows(&database);
    try lab.createTable(&database, "after-cancel");

    try runMark(&runner, &database);
    try runSweep(&runner, &database);
    try expectRetainedRows(&database);
}

fn exerciseReopen(comptime Database: type, options: Database.InitOptions) !void {
    const image = image: {
        var database = try formatDatabase(Database, options);
        defer database.deinit();
        try prepareDisconnectedTable(&database);

        var runner = GcRunner.init();
        defer runner.deinit();
        try runner.requestMark(1);
        try std.testing.expect(try runner.pump(&database));
        while (try database.garbageCollectionPhase() == .preparing) {
            try std.testing.expect(try runner.pump(&database));
        }
        try std.testing.expectEqual(fullaz.gc.Phase.marking, try database.garbageCollectionPhase());
        try std.testing.expect(try runner.pump(&database));
        try std.testing.expectEqual(fullaz.gc.Phase.marking, try database.garbageCollectionPhase());
        break :image try std.testing.allocator.dupe(u8, database.deviceBytes());
    };
    defer std.testing.allocator.free(image);

    var database = try openDatabase(Database, image, options);
    defer database.deinit();
    var runner = GcRunner.init();
    defer runner.deinit();
    runner.restore(try database.garbageCollectionPhase());

    try std.testing.expectEqual(GcRunner.State.marking, runner.state());
    try std.testing.expect(!runner.hasPendingWork());
    try runMark(&runner, &database);
    try expectRetainedRows(&database);
    try runSweep(&runner, &database);
    try expectRetainedRows(&database);
    try lab.createTable(&database, "after-reopen");
}

test "db-lab GC runner completes collection with static WAL" {
    try exerciseCompletion(StaticDatabase, static_options);
}

test "db-lab GC runner completes collection with virtual WAL" {
    try exerciseCompletion(VirtualDatabase, virtual_options);
}

test "db-lab GC runner completes collection with dynamic WAL" {
    try exerciseCompletion(DynamicDatabase, dynamic_options);
}

test "db-lab GC runner cancels collection with static WAL" {
    try exerciseCancellation(StaticDatabase, static_options);
}

test "db-lab GC runner cancels collection with virtual WAL" {
    try exerciseCancellation(VirtualDatabase, virtual_options);
}

test "db-lab GC runner cancels collection with dynamic WAL" {
    try exerciseCancellation(DynamicDatabase, dynamic_options);
}

test "db-lab GC runner resumes a static WAL image" {
    try exerciseReopen(StaticDatabase, static_options);
}

test "db-lab GC runner resumes a virtual WAL image" {
    try exerciseReopen(VirtualDatabase, virtual_options);
}

test "db-lab GC runner resumes a dynamic WAL image" {
    try exerciseReopen(DynamicDatabase, dynamic_options);
}
