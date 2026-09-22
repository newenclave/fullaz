const fullaz = @import("fullaz");

const atomic = fullaz.zync.atomic;
const Storage = fullaz.zync.queue_storage.Storage(u32).Fixed(4);
const Queue = fullaz.zync.TaskQueue(fullaz.zync.policies.SpinSync, Storage);

fn matchesValue(expected: u32, task: *const u32) bool {
    return task.* == expected;
}

export fn zyncSpinQueueSmoke(value: u32) u32 {
    var queue = Queue.init(.init(), .{});
    defer queue.deinit();

    queue.push(value) catch unreachable;
    return queue.popIf(value, matchesValue) orelse unreachable;
}

export fn zyncSpinQueueWait(queue: *Queue) void {
    queue.wait();
}

export fn zyncSpinQueueWaitPop(queue: *Queue) u32 {
    return queue.waitPop();
}

export fn zyncSpinLockSmoke(lock: *atomic.SpinLock) void {
    lock.lock();
    lock.unlock();
}

export fn zyncSpinConditionWait(
    condition: *atomic.CondVariable,
    lock: *atomic.SpinLock,
) void {
    condition.wait(lock);
}

export fn zyncSpinConditionNotify(condition: *atomic.CondVariable) void {
    condition.notifyOne();
    condition.notifyAll();
}
