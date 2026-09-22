const std = @import("std");
const fullaz = @import("fullaz");

const zync = fullaz.zync;

test "Zync task queue: no-sync fixed queue is FIFO" {
    const Queue = zync.TaskQueue(
        zync.policies.NoSync,
        zync.queue_storage.Storage(i32).Fixed(2),
    );
    var queue = Queue.init(.{}, .{});
    defer queue.deinit();

    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(?i32, null), queue.pop());
    try queue.push(1);
    try queue.push(2);
    try std.testing.expectError(error.NotEnoughSpace, queue.push(3));
    try std.testing.expectEqual(@as(?i32, 1), queue.pop());
    try std.testing.expectEqual(@as(?i32, 2), queue.pop());
    try std.testing.expect(queue.isEmpty());
}

fn compareInt(_: void, left: i32, right: i32) std.math.Order {
    return std.math.order(left, right);
}

test "Zync task queue: storage policy controls task order" {
    const Queue = zync.TaskQueue(
        zync.policies.NoSync,
        zync.queue_storage.Storage(i32).Priority(void, compareInt),
    );
    var queue = Queue.init(.{}, .init(std.testing.allocator, {}));
    defer queue.deinit();

    try queue.push(3);
    try queue.push(1);
    try queue.push(2);
    try std.testing.expectEqual(@as(?i32, 1), queue.pop());
    try std.testing.expectEqual(@as(?i32, 2), queue.pop());
    try std.testing.expectEqual(@as(?i32, 3), queue.pop());
}

const TrackingSync = struct {
    pub const supports_wait = false;

    locked: *bool,

    fn init(locked: *bool) TrackingSync {
        return .{ .locked = locked };
    }

    pub fn lock(self: *TrackingSync) void {
        std.debug.assert(!self.locked.*);
        self.locked.* = true;
    }

    pub fn unlock(self: *TrackingSync) void {
        std.debug.assert(self.locked.*);
        self.locked.* = false;
    }

    pub fn notifyOne(_: *TrackingSync) void {}
};

const TestNextContext = struct {
    locked: *const bool,
    expected: i32,
    call_count: usize = 0,
    called_while_locked: bool = false,
    observed: ?i32 = null,
};

fn testNextPredicate(ctx: *TestNextContext, task: *const i32) bool {
    ctx.call_count += 1;
    ctx.called_while_locked = ctx.locked.*;
    ctx.observed = task.*;
    return task.* == ctx.expected;
}

test "Zync task queue: testNext checks a snapshot after unlocking" {
    const Queue = zync.TaskQueue(
        TrackingSync,
        zync.queue_storage.Storage(i32).Fixed(1),
    );

    var locked = false;
    var queue = Queue.init(.init(&locked), .{});
    defer queue.deinit();

    var context = TestNextContext{
        .locked = &locked,
        .expected = 7,
    };

    try std.testing.expect(!queue.testNext(&context, testNextPredicate));
    try std.testing.expectEqual(@as(usize, 0), context.call_count);

    try queue.push(7);
    try std.testing.expect(queue.testNext(&context, testNextPredicate));
    try std.testing.expectEqual(@as(usize, 1), context.call_count);
    try std.testing.expect(!context.called_while_locked);
    try std.testing.expectEqual(@as(?i32, 7), context.observed);

    context.expected = 8;
    try std.testing.expect(!queue.testNext(&context, testNextPredicate));
    try std.testing.expectEqual(@as(usize, 2), context.call_count);
    try std.testing.expectEqual(@as(?i32, 7), queue.pop());
}

test "Zync task queue: popIf tests and removes the head under one lock" {
    const Queue = zync.TaskQueue(
        TrackingSync,
        zync.queue_storage.Storage(i32).Fixed(2),
    );

    var locked = false;
    var queue = Queue.init(.init(&locked), .{});
    defer queue.deinit();

    var context = TestNextContext{
        .locked = &locked,
        .expected = 8,
    };

    try std.testing.expectEqual(
        @as(?i32, null),
        queue.popIf(&context, testNextPredicate),
    );
    try std.testing.expectEqual(@as(usize, 0), context.call_count);

    try queue.push(7);
    try queue.push(8);
    try std.testing.expectEqual(
        @as(?i32, null),
        queue.popIf(&context, testNextPredicate),
    );
    try std.testing.expectEqual(@as(usize, 1), context.call_count);
    try std.testing.expect(context.called_while_locked);

    context.expected = 7;
    try std.testing.expectEqual(
        @as(?i32, 7),
        queue.popIf(&context, testNextPredicate),
    );
    try std.testing.expectEqual(@as(usize, 2), context.call_count);
    try std.testing.expect(context.called_while_locked);
    try std.testing.expectEqual(@as(?i32, 8), queue.pop());
}

fn matchesInt(expected: i32, task: *const i32) bool {
    return task.* == expected;
}

test "Zync task queue: deque popIf checks only the head" {
    const Queue = zync.TaskQueue(
        zync.policies.NoSync,
        zync.queue_storage.Storage(i32).Deque,
    );
    var queue = Queue.init(.{}, .init(std.testing.allocator));
    defer queue.deinit();

    try queue.push(1);
    try queue.push(2);
    try std.testing.expectEqual(
        @as(?i32, null),
        queue.popIf(@as(i32, 2), matchesInt),
    );
    try std.testing.expectEqual(
        @as(?i32, 1),
        queue.popIf(@as(i32, 1), matchesInt),
    );
    try std.testing.expectEqual(@as(?i32, 2), queue.pop());
}

const ScheduledTask = struct {
    id: u32,
    due_tick: u64,
};

fn compareScheduledTask(_: void, left: ScheduledTask, right: ScheduledTask) std.math.Order {
    return std.math.order(left.due_tick, right.due_tick);
}

fn isTaskDue(current_tick: u64, task: *const ScheduledTask) bool {
    return task.due_tick <= current_tick;
}

test "Zync task queue: stable priority popIf preserves due task order" {
    const Queue = zync.TaskQueue(
        zync.policies.NoSync,
        zync.queue_storage.Storage(ScheduledTask).StablePriority(
            void,
            compareScheduledTask,
        ),
    );
    var queue = Queue.init(.{}, .init(std.testing.allocator, {}));
    defer queue.deinit();

    try queue.push(.{ .id = 10, .due_tick = 10 });
    try queue.push(.{ .id = 5, .due_tick = 5 });
    try queue.push(.{ .id = 7, .due_tick = 7 });
    try queue.push(.{ .id = 8, .due_tick = 7 });

    try std.testing.expectEqual(
        @as(?ScheduledTask, null),
        queue.popIf(@as(u64, 4), isTaskDue),
    );
    try std.testing.expectEqual(
        @as(u32, 5),
        queue.popIf(@as(u64, 5), isTaskDue).?.id,
    );
    try std.testing.expectEqual(
        @as(?ScheduledTask, null),
        queue.popIf(@as(u64, 6), isTaskDue),
    );
    try std.testing.expectEqual(
        @as(u32, 7),
        queue.popIf(@as(u64, 7), isTaskDue).?.id,
    );
    try std.testing.expectEqual(
        @as(u32, 8),
        queue.popIf(@as(u64, 7), isTaskDue).?.id,
    );
    try std.testing.expectEqual(
        @as(u32, 10),
        queue.popIf(@as(u64, 100), isTaskDue).?.id,
    );
    try std.testing.expectEqual(
        @as(?ScheduledTask, null),
        queue.popIf(@as(u64, 100), isTaskDue),
    );
}

const WaitQueue = zync.TaskQueue(
    zync.policies.SpinSync,
    zync.queue_storage.Storage(i32).Fixed(1),
);

const WaitContext = struct {
    queue: *WaitQueue,
    started: std.atomic.Value(bool) = .init(false),
    returned: std.atomic.Value(bool) = .init(false),

    fn run(self: *WaitContext) void {
        self.started.store(true, .release);
        self.queue.wait();
        self.returned.store(true, .release);
    }
};

test "Zync task queue: wait leaves the task in the queue" {
    var queue = WaitQueue.init(.init(), .{});
    defer queue.deinit();

    var context = WaitContext{ .queue = &queue };
    const thread = try std.Thread.spawn(.{}, WaitContext.run, .{&context});
    while (!context.started.load(.acquire)) {
        std.atomic.spinLoopHint();
    }

    try queue.push(7);
    thread.join();

    try std.testing.expect(context.returned.load(.acquire));
    try std.testing.expectEqual(@as(?i32, 7), queue.pop());
}

const IoQueue = zync.TaskQueue(
    zync.policies.IoSync,
    zync.queue_storage.Storage(i32).Fixed(1),
);

const IoConsumer = struct {
    queue: *IoQueue,
    task: *i32,

    fn run(self: *IoConsumer) void {
        self.task.* = self.queue.waitPop();
    }
};

test "Zync task queue: IoSync waitPop receives a task" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    var queue = IoQueue.init(.init(threaded.io()), .{});
    defer queue.deinit();

    var task: i32 = 0;
    var consumer = IoConsumer{ .queue = &queue, .task = &task };
    const thread = try std.Thread.spawn(.{}, IoConsumer.run, .{&consumer});

    try queue.push(9);
    thread.join();
    try std.testing.expectEqual(@as(i32, 9), task);
}

const concurrent_task_count = 128;
const ConcurrentQueue = zync.TaskQueue(
    zync.policies.SpinSync,
    zync.queue_storage.Storage(usize).Deque,
);

fn acceptTask(_: void, _: *const usize) bool {
    return true;
}

const PopIfConsumer = struct {
    queue: *ConcurrentQueue,
    start: *std.atomic.Value(bool),
    pop_count: *std.atomic.Value(usize),
    value_sum: *std.atomic.Value(usize),

    fn run(self: *PopIfConsumer) void {
        while (!self.start.load(.acquire)) {
            std.atomic.spinLoopHint();
        }
        if (self.queue.popIf({}, acceptTask)) |task| {
            _ = self.pop_count.fetchAdd(1, .monotonic);
            _ = self.value_sum.fetchAdd(task, .monotonic);
        }
    }
};

test "Zync task queue: concurrent popIf removes one task once" {
    var queue = ConcurrentQueue.init(.init(), .init(std.testing.allocator));
    defer queue.deinit();
    try queue.push(41);

    var start = std.atomic.Value(bool).init(false);
    var pop_count = std.atomic.Value(usize).init(0);
    var value_sum = std.atomic.Value(usize).init(0);
    var consumers: [8]PopIfConsumer = undefined;
    var threads: [consumers.len]std.Thread = undefined;

    for (&consumers, &threads) |*consumer, *thread| {
        consumer.* = .{
            .queue = &queue,
            .start = &start,
            .pop_count = &pop_count,
            .value_sum = &value_sum,
        };
        thread.* = try std.Thread.spawn(.{}, PopIfConsumer.run, .{consumer});
    }

    start.store(true, .release);
    for (&threads) |*thread| {
        thread.join();
    }

    try std.testing.expectEqual(@as(usize, 1), pop_count.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 41), value_sum.load(.monotonic));
    try std.testing.expect(queue.isEmpty());
}

const Producer = struct {
    queue: *ConcurrentQueue,
    first: usize,
    count: usize,

    fn run(self: *Producer) void {
        for (self.first..self.first + self.count) |task| {
            self.queue.push(task) catch unreachable;
        }
    }
};

const Consumer = struct {
    queue: *ConcurrentQueue,
    seen: *[concurrent_task_count]std.atomic.Value(u8),
    count: usize,

    fn run(self: *Consumer) void {
        for (0..self.count) |_| {
            const task = self.queue.waitPop();
            _ = self.seen[task].fetchAdd(1, .monotonic);
        }
    }
};

test "Zync task queue: concurrent waitPop consumes every task once" {
    var queue = ConcurrentQueue.init(.init(), .init(std.testing.allocator));
    defer queue.deinit();

    var seen: [concurrent_task_count]std.atomic.Value(u8) = undefined;
    for (&seen) |*value| {
        value.* = .init(0);
    }

    var consumers = [_]Consumer{
        .{ .queue = &queue, .seen = &seen, .count = 32 },
        .{ .queue = &queue, .seen = &seen, .count = 32 },
        .{ .queue = &queue, .seen = &seen, .count = 32 },
        .{ .queue = &queue, .seen = &seen, .count = 32 },
    };
    var consumer_threads: [consumers.len]std.Thread = undefined;
    for (&consumers, &consumer_threads) |*consumer, *thread| {
        thread.* = try std.Thread.spawn(.{}, Consumer.run, .{consumer});
    }

    var producers = [_]Producer{
        .{ .queue = &queue, .first = 0, .count = 64 },
        .{ .queue = &queue, .first = 64, .count = 64 },
    };
    var producer_threads: [producers.len]std.Thread = undefined;
    for (&producers, &producer_threads) |*producer, *thread| {
        thread.* = try std.Thread.spawn(.{}, Producer.run, .{producer});
    }

    for (&producer_threads) |*thread| {
        thread.join();
    }
    for (&consumer_threads) |*thread| {
        thread.join();
    }

    for (&seen) |*value| {
        try std.testing.expectEqual(@as(u8, 1), value.load(.monotonic));
    }
    try std.testing.expect(queue.isEmpty());
}
