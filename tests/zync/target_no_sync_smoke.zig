const fullaz = @import("fullaz");

const Storage = fullaz.zync.queue_storage.Storage(u32).Fixed(4);
const Queue = fullaz.zync.TaskQueue(fullaz.zync.policies.NoSync, Storage);

fn matchesValue(expected: u32, task: *const u32) bool {
    return task.* == expected;
}

export fn zyncNoSyncQueueSmoke(value: u32) u32 {
    var queue = Queue.init(.{}, .{});
    defer queue.deinit();

    if (!queue.isEmpty()) {
        unreachable;
    }
    queue.push(value) catch unreachable;
    return queue.popIf(value, matchesValue) orelse unreachable;
}
