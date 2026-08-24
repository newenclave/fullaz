const std = @import("std");
const fullaz = @import("fullaz");

const Event = struct {
    value: u32,
};
const Observer = fullaz.zync.ObserverImpl(
    fullaz.zync.policies.NoSync,
    fullaz.zync.storage.Dynamic,
    Event,
    u32,
);
const FixedObserver = fullaz.zync.ObserverImpl(
    fullaz.zync.policies.NoSync,
    fullaz.zync.storage.Fixed(2),
    Event,
    u32,
);

fn addValue(ctx: ?*anyopaque, event: *const Event) void {
    const total: *u32 = @ptrCast(@alignCast(ctx.?));
    total.* += event.value;
}

test "Zync observer: subscribe, notify, and unsubscribe" {
    var observer = Observer.init(.{}, .init(std.testing.allocator));
    defer observer.deinit();

    var total: u32 = 0;
    const id = try observer.subscribe(addValue, &total);

    try observer.notify(&.{ .value = 3 });
    try std.testing.expectEqual(@as(u32, 3), total);

    const removed = observer.unsubscribe(id).?;
    try std.testing.expectEqual(@as(?*anyopaque, &total), removed.ctx);
    try observer.notify(&.{ .value = 5 });
    try std.testing.expectEqual(@as(u32, 3), total);
    try std.testing.expect(observer.unsubscribe(id) == null);
}

const SelfRemoving = struct {
    observer: *Observer,
    id: u32 = 0,
    calls: u32 = 0,

    fn call(ctx: ?*anyopaque, _: *const Event) void {
        const self: *SelfRemoving = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        _ = self.observer.unsubscribe(self.id);
    }
};

test "Zync observer: callbacks may unsubscribe from a notification snapshot" {
    var observer = Observer.init(.{}, .init(std.testing.allocator));
    defer observer.deinit();

    var subscriber = SelfRemoving{ .observer = &observer };
    subscriber.id = try observer.subscribe(SelfRemoving.call, &subscriber);

    try observer.notify(&.{ .value = 1 });
    try observer.notify(&.{ .value = 2 });
    try std.testing.expectEqual(@as(u32, 1), subscriber.calls);
}

test "Zync observer: fixed storage does not allocate and enforces its limit" {
    var observer = FixedObserver.init(.{}, .{});
    defer observer.deinit();

    var first: u32 = 0;
    var second: u32 = 0;
    var third: u32 = 0;
    _ = try observer.subscribe(addValue, &first);
    _ = try observer.subscribe(addValue, &second);
    try std.testing.expectError(
        error.NotEnoughSpace,
        observer.subscribe(addValue, &third),
    );

    try observer.notify(&.{ .value = 4 });
    try std.testing.expectEqual(@as(u32, 4), first);
    try std.testing.expectEqual(@as(u32, 4), second);
}

const FixedSelfRemoving = struct {
    observer: *FixedObserver,
    id: u32 = 0,
    calls: u32 = 0,

    fn call(ctx: ?*anyopaque, _: *const Event) void {
        const self: *FixedSelfRemoving = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        _ = self.observer.unsubscribe(self.id);
    }
};

test "Zync observer: fixed notification snapshot permits self-unsubscribe" {
    var observer = FixedObserver.init(.{}, .{});
    defer observer.deinit();

    var subscriber = FixedSelfRemoving{ .observer = &observer };
    subscriber.id = try observer.subscribe(FixedSelfRemoving.call, &subscriber);

    try observer.notify(&.{ .value = 1 });
    try observer.notify(&.{ .value = 2 });
    try std.testing.expectEqual(@as(u32, 1), subscriber.calls);
}
