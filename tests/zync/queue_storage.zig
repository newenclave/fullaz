const std = @import("std");
const fullaz = @import("fullaz");

const queue_storage = fullaz.zync.queue_storage;

test "Zync queue storage: deque is FIFO and can refill" {
    const Storage = queue_storage.Storage(i32).Deque;
    var storage = Storage.init(.init(std.testing.allocator));
    defer storage.deinit();

    try std.testing.expect(storage.isEmpty());
    try std.testing.expectEqual(@as(?i32, null), storage.peek());
    try storage.push(1);
    try storage.push(2);
    try std.testing.expectEqual(@as(?i32, 1), storage.peek());
    try std.testing.expectEqual(@as(?i32, 1), storage.pop());
    try std.testing.expectEqual(@as(?i32, 2), storage.peek());
    try storage.push(3);
    try std.testing.expectEqual(@as(?i32, 2), storage.pop());
    try std.testing.expectEqual(@as(?i32, 3), storage.pop());
    try std.testing.expectEqual(@as(?i32, null), storage.pop());
    try std.testing.expectEqual(@as(?i32, null), storage.peek());
    try std.testing.expect(storage.isEmpty());
}

test "Zync queue storage: fixed ring wraps without overwriting tasks" {
    const Storage = queue_storage.Storage(i32).Fixed(3);
    var storage = Storage.init(.{});
    defer storage.deinit();

    try std.testing.expectEqual(@as(?i32, null), storage.peek());
    try storage.push(1);
    try storage.push(2);
    try storage.push(3);
    try std.testing.expectEqual(@as(?i32, 1), storage.peek());
    try std.testing.expectError(error.NotEnoughSpace, storage.push(4));

    try std.testing.expectEqual(@as(?i32, 1), storage.pop());
    try std.testing.expectEqual(@as(?i32, 2), storage.pop());
    try storage.push(4);
    try storage.push(5);

    try std.testing.expectEqual(@as(?i32, 3), storage.peek());
    try std.testing.expectEqual(@as(?i32, 3), storage.pop());
    try std.testing.expectEqual(@as(?i32, 4), storage.pop());
    try std.testing.expectEqual(@as(?i32, 5), storage.pop());
    try std.testing.expectEqual(@as(?i32, null), storage.pop());
    try std.testing.expectEqual(@as(?i32, null), storage.peek());
}

test "Zync queue storage: fixed ring supports capacity one" {
    const Storage = queue_storage.Storage(i32).Fixed(1);
    var storage = Storage.init(.{});
    defer storage.deinit();

    try storage.push(1);
    try std.testing.expectError(error.NotEnoughSpace, storage.push(2));
    try std.testing.expectEqual(@as(?i32, 1), storage.pop());
    try storage.push(2);
    try std.testing.expectEqual(@as(?i32, 2), storage.pop());
}

fn compareInt(_: void, left: i32, right: i32) std.math.Order {
    return std.math.order(left, right);
}

test "Zync queue storage: priority pops in comparator order" {
    const Storage = queue_storage.Storage(i32).Priority(void, compareInt);
    var storage = Storage.init(.init(std.testing.allocator, {}));
    defer storage.deinit();

    try std.testing.expectEqual(@as(?i32, null), storage.peek());
    try storage.push(3);
    try storage.push(1);
    try storage.push(2);

    try std.testing.expectEqual(@as(?i32, 1), storage.peek());
    try std.testing.expectEqual(@as(?i32, 1), storage.pop());
    try std.testing.expectEqual(@as(?i32, 2), storage.peek());
    try std.testing.expectEqual(@as(?i32, 2), storage.pop());
    try std.testing.expectEqual(@as(?i32, 3), storage.pop());
    try std.testing.expectEqual(@as(?i32, null), storage.pop());
    try std.testing.expectEqual(@as(?i32, null), storage.peek());
}
