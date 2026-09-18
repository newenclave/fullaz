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
