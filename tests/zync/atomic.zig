const std = @import("std");
const fullaz = @import("fullaz");

const atomic = fullaz.zync.atomic;

const Counter = struct {
    lock: atomic.SpinLock = .init(),
    value: usize = 0,
};

fn incrementCounter(counter: *Counter) void {
    for (0..10_000) |_| {
        counter.lock.lock();
        counter.value += 1;
        counter.lock.unlock();
    }
}

test "Zync atomic: spin lock provides mutual exclusion" {
    var counter: Counter = .{};
    var threads: [4]std.Thread = undefined;

    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, incrementCounter, .{&counter});
    }
    for (&threads) |*thread| {
        thread.join();
    }

    try std.testing.expectEqual(@as(usize, 40_000), counter.value);
}

const WaitState = struct {
    lock: atomic.SpinLock = .init(),
    condition: atomic.CondVariable = .init(),
    ready: std.atomic.Value(usize) = .init(0),
    woke: std.atomic.Value(usize) = .init(0),
    proceed: bool = false,
};

fn waitForProceed(state: *WaitState) void {
    state.lock.lock();
    _ = state.ready.fetchAdd(1, .release);
    while (!state.proceed) {
        state.condition.wait(&state.lock);
    }
    _ = state.woke.fetchAdd(1, .release);
    state.lock.unlock();
}

fn waitUntil(value: *std.atomic.Value(usize), expected: usize) void {
    while (value.load(.acquire) != expected) {
        std.atomic.spinLoopHint();
    }
}

test "Zync atomic: condition variable notifies one waiter" {
    var state: WaitState = .{};
    const thread = try std.Thread.spawn(.{}, waitForProceed, .{&state});

    waitUntil(&state.ready, 1);
    state.lock.lock();
    state.proceed = true;
    state.condition.notifyOne();
    state.lock.unlock();

    thread.join();
    try std.testing.expectEqual(@as(usize, 1), state.woke.load(.acquire));
}

test "Zync atomic: condition variable notifies all registered waiters" {
    var state: WaitState = .{};
    var threads: [4]std.Thread = undefined;

    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, waitForProceed, .{&state});
    }

    waitUntil(&state.ready, threads.len);
    state.lock.lock();
    state.proceed = true;
    state.condition.notifyAll();
    state.lock.unlock();

    for (&threads) |*thread| {
        thread.join();
    }
    try std.testing.expectEqual(threads.len, state.woke.load(.acquire));
}
