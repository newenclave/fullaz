const std = @import("std");
const fullaz = @import("fullaz");
const range_aggregate = fullaz.range_aggregate;

test "RangeAggregate opens its projected paged B+ tree and preserves its root" {
    const Device = fullaz.device.MemoryBlock(u32);
    const PageCache = fullaz.storage.page_cache.PageCache(Device);
    const State = range_aggregate.State(u32, i32, .little);
    const Lease = struct {
        pub const Error = error{};

        state: *State,

        pub fn data(self: *const @This()) Error![]const u8 {
            return std.mem.asBytes(self.state);
        }

        pub fn dataMut(self: *@This()) Error![]u8 {
            return std.mem.asBytes(self.state);
        }

        pub fn finish(_: *@This()) void {}
        pub fn deinit(_: *@This()) void {}
    };
    const ParentManager = struct {
        pub const PageId = u32;
        pub const Error = error{};
        pub const StateLeaseType = Lease;

        durable_state: State,

        pub fn state(self: *@This()) Error!StateLeaseType {
            return .{ .state = &self.durable_state };
        }

        pub fn destroyPage(_: *@This(), _: PageId) Error!void {}
    };
    const Aggregate = range_aggregate.RangeAggregate(PageCache, ParentManager, i32, .little);
    const Key = range_aggregate.Key(i32, .little);
    const settings: range_aggregate.Settings(i32) = .{
        .base_width = 2,
        .level_count = 3,
        .value_size = 8,
    };

    var device = try Device.init(std.testing.allocator, 512);
    defer device.deinit();
    var cache = try PageCache.init(&device, std.testing.allocator, 4);
    defer cache.deinit();
    var parent: ParentManager = .{ .durable_state = try State.init(settings) };

    var aggregate: Aggregate = undefined;
    try aggregate.init(&cache, &parent, .{ .leaf_page_kind = 10, .inode_page_kind = 11 });
    const key: Key = .{ .level = 1, .value = .init(4) };
    try std.testing.expect(try aggregate.bpt().insert(std.mem.asBytes(&key), "value123"));
    aggregate.deinit();
    try std.testing.expect(!parent.durable_state.tree.root.isMax());

    var reopened: Aggregate = undefined;
    try reopened.init(&cache, &parent, .{ .leaf_page_kind = 10, .inode_page_kind = 11 });
    defer reopened.deinit();
    try std.testing.expectEqualDeep(settings, reopened.settings());
    var iterator = (try reopened.bpt().find(std.mem.asBytes(&key))).?;
    const entry = (try iterator.get()).?;
    try std.testing.expectEqualSlices(u8, "value123", entry.value);
    iterator.deinit();

    try reopened.destroy();
    try std.testing.expect(parent.durable_state.tree.root.isMax());
}

test "RangeAggregate insert calls level callbacks with live stored values" {
    const Device = fullaz.device.MemoryBlock(u32);
    const PageCache = fullaz.storage.page_cache.PageCache(Device);
    const State = range_aggregate.State(u32, i32, .little);
    const Lease = struct {
        pub const Error = error{};

        state: *State,

        pub fn data(self: *const @This()) Error![]const u8 {
            return std.mem.asBytes(self.state);
        }

        pub fn dataMut(self: *@This()) Error![]u8 {
            return std.mem.asBytes(self.state);
        }

        pub fn finish(_: *@This()) void {}
        pub fn deinit(_: *@This()) void {}
    };
    const ParentManager = struct {
        pub const PageId = u32;
        pub const Error = error{};
        pub const StateLeaseType = Lease;

        durable_state: State,

        pub fn state(self: *@This()) Error!StateLeaseType {
            return .{ .state = &self.durable_state };
        }

        pub fn destroyPage(_: *@This(), _: PageId) Error!void {}
    };
    const Aggregate = range_aggregate.RangeAggregate(PageCache, ParentManager, i32, .little);
    const Context = struct {
        inserted: [3]bool = [_]bool{false} ** 3,
        updated: [3]bool = [_]bool{false} ** 3,
    };
    const Callbacks = struct {
        fn onInsert(context: *Context, info: range_aggregate.LevelInfo(i32), stored: []u8) void {
            context.inserted[info.level] = true;
            stored[0] = info.level;
        }

        fn onUpdate(
            context: *Context,
            info: range_aggregate.LevelInfo(i32),
            stored: []u8,
            input: []const u8,
        ) error{UnexpectedInput}!void {
            if (!std.mem.eql(u8, input, "second12")) {
                return error.UnexpectedInput;
            }
            context.updated[info.level] = true;
            stored[1] = info.level;
        }
    };
    const FailingCallbacks = struct {
        fn onInsert(_: *Context, _: range_aggregate.LevelInfo(i32), stored: []u8) error{CallbackFailed}!void {
            stored[0] = 0xff;
            return error.CallbackFailed;
        }

        fn onUpdate(_: *Context, _: range_aggregate.LevelInfo(i32), _: []u8, _: []const u8) void {}
    };
    const settings: range_aggregate.Settings(i32) = .{
        .base_width = 2,
        .level_count = 3,
        .value_size = 8,
    };

    var device = try Device.init(std.testing.allocator, 512);
    defer device.deinit();
    var cache = try PageCache.init(&device, std.testing.allocator, 4);
    defer cache.deinit();
    var parent: ParentManager = .{ .durable_state = try State.init(settings) };
    var aggregate: Aggregate = undefined;
    try aggregate.init(&cache, &parent, .{ .leaf_page_kind = 10, .inode_page_kind = 11 });
    defer aggregate.deinit();

    var context = Context{};
    try std.testing.expectError(
        error.InvalidInputSize,
        aggregate.insert(4, "short", &context, Callbacks.onInsert, Callbacks.onUpdate),
    );
    try std.testing.expectEqual([_]bool{ false, false, false }, context.inserted);
    try aggregate.insert(4, "first123", &context, Callbacks.onInsert, Callbacks.onUpdate);
    try std.testing.expectEqual([_]bool{ true, true, true }, context.inserted);
    try std.testing.expectEqual([_]bool{ false, false, false }, context.updated);
    try aggregate.insert(4, "second12", &context, Callbacks.onInsert, Callbacks.onUpdate);
    try std.testing.expectEqual([_]bool{ true, true, true }, context.updated);
    try std.testing.expectError(
        error.CallbackFailed,
        aggregate.insert(10, "failure1", &context, FailingCallbacks.onInsert, FailingCallbacks.onUpdate),
    );
    const Key = range_aggregate.Key(i32, .little);
    const failed_key: Key = .{ .level = 0, .value = .init(10) };
    var iterator = (try aggregate.bpt().find(std.mem.asBytes(&failed_key))).?;
    defer iterator.deinit();
    try std.testing.expectEqualSlices(u8, "failure1", (try iterator.get()).?.value);
}

test "RangeAggregate accumulate visits existing B-adic cover buckets" {
    const Device = fullaz.device.MemoryBlock(u32);
    const PageCache = fullaz.storage.page_cache.PageCache(Device);
    const State = range_aggregate.State(u32, i32, .little);
    const Lease = struct {
        pub const Error = error{};

        state: *State,

        pub fn data(self: *const @This()) Error![]const u8 {
            return std.mem.asBytes(self.state);
        }

        pub fn dataMut(self: *@This()) Error![]u8 {
            return std.mem.asBytes(self.state);
        }

        pub fn finish(_: *@This()) void {}
        pub fn deinit(_: *@This()) void {}
    };
    const ParentManager = struct {
        pub const PageId = u32;
        pub const Error = error{};
        pub const StateLeaseType = Lease;

        durable_state: State,

        pub fn state(self: *@This()) Error!StateLeaseType {
            return .{ .state = &self.durable_state };
        }

        pub fn destroyPage(_: *@This(), _: PageId) Error!void {}
    };
    const Aggregate = range_aggregate.RangeAggregate(PageCache, ParentManager, i32, .little);
    const Context = struct {
        levels: [3]bool = [_]bool{false} ** 3,
        calls: usize = 0,
    };
    const Callbacks = struct {
        fn onInsert(_: *Context, _: range_aggregate.LevelInfo(i32), _: []u8) void {}

        fn onUpdate(_: *Context, _: range_aggregate.LevelInfo(i32), _: []u8, _: []const u8) void {}

        fn onAccumulate(
            context: *Context,
            info: range_aggregate.LevelInfo(i32),
            stored: []const u8,
        ) error{BadValue}!void {
            if (!std.mem.eql(u8, stored, "value123")) {
                return error.BadValue;
            }
            context.levels[info.level] = true;
            context.calls += 1;
        }
    };
    const settings: range_aggregate.Settings(i32) = .{
        .base_width = 2,
        .level_count = 3,
        .value_size = 8,
    };

    var device = try Device.init(std.testing.allocator, 512);
    defer device.deinit();
    var cache = try PageCache.init(&device, std.testing.allocator, 4);
    defer cache.deinit();
    var parent: ParentManager = .{ .durable_state = try State.init(settings) };
    var aggregate: Aggregate = undefined;
    try aggregate.init(&cache, &parent, .{ .leaf_page_kind = 10, .inode_page_kind = 11 });
    defer aggregate.deinit();

    var context = Context{};
    try aggregate.insert(4, "value123", &context, Callbacks.onInsert, Callbacks.onUpdate);
    var cover_output: [3]range_aggregate.LevelInfo(i32) = undefined;
    try aggregate.accumulate(
        .{ .from = 4, .to = 6 },
        .{ .policy = .exact },
        2,
        &cover_output,
        &context,
        Callbacks.onAccumulate,
    );
    try std.testing.expectEqual(@as(usize, 1), context.calls);
    try std.testing.expectEqual([_]bool{ true, false, false }, context.levels);

    context = .{};
    try aggregate.accumulate(
        .{ .from = 4, .to = 8 },
        .{ .policy = .exact },
        2,
        &cover_output,
        &context,
        Callbacks.onAccumulate,
    );
    try std.testing.expectEqual(@as(usize, 1), context.calls);
    try std.testing.expectEqual([_]bool{ false, true, false }, context.levels);

    context = .{};
    try aggregate.accumulate(
        .{ .from = 6, .to = 8 },
        .{ .policy = .exact },
        0,
        &cover_output,
        &context,
        Callbacks.onAccumulate,
    );
    try std.testing.expectEqual(@as(usize, 0), context.calls);
}
