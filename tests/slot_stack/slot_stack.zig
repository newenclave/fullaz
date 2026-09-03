const std = @import("std");
const fullaz = @import("fullaz");

const Device = fullaz.device.MemoryBlock(u32);
const Cache = fullaz.storage.page_cache.PageCache(Device);
const SlotStack = fullaz.storage.slot_stack.SlotStack;
const StackState = fullaz.storage.slot_stack.State(u32, u32, u32, .little);

const StorageManager = struct {
    pub const PageId = u32;
    pub const Error = error{};
    pub const StateLeaseType = struct {
        pub const Error = error{};

        value: *StackState,

        pub fn data(self: *const @This()) @This().Error![]const u8 {
            return std.mem.asBytes(@as(*const StackState, self.value));
        }

        pub fn dataMut(self: *@This()) @This().Error![]u8 {
            return std.mem.asBytes(self.value);
        }

        pub fn finish(_: *@This()) void {}
        pub fn deinit(_: *@This()) void {}
    };

    state_value: StackState = .{},

    pub fn state(self: *@This()) Error!StateLeaseType {
        return .{ .value = &self.state_value };
    }

    pub fn destroyPage(_: *@This(), _: PageId) Error!void {}
};

test "SlotStack: push, top, pop, and iterate" {
    const Stack = SlotStack(Cache, StorageManager, u32, u32, .little);

    var manager = StorageManager{};
    var device = try Device.init(std.testing.allocator, 4096);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 8);
    defer cache.deinit();
    var stack = try Stack.init(&cache, &manager, .{});
    defer stack.deinit();

    try std.testing.expectError(error.EmptySet, stack.top());
    try std.testing.expectError(error.EmptySet, stack.pop());

    try stack.push("first");
    try stack.push("second");
    try stack.push("third");
    try std.testing.expectEqual(@as(usize, 3), try stack.size());

    var top = try stack.top();
    defer top.deinit();
    try std.testing.expectEqualStrings("third", try top.value());

    var iterator = (try stack.iterator()).?;
    defer iterator.deinit();
    try std.testing.expectEqualStrings("first", (try iterator.next()).?);
    try std.testing.expectEqualStrings("second", (try iterator.next()).?);
    try std.testing.expectEqualStrings("third", (try iterator.next()).?);
    try std.testing.expect((try iterator.next()) == null);

    try stack.pop();
    try stack.pop();
    var remaining = try stack.top();
    defer remaining.deinit();
    try std.testing.expectEqualStrings("first", try remaining.value());
    try stack.pop();
    try std.testing.expect(try stack.isEmpty());
    try std.testing.expectError(error.EmptySet, stack.pop());
}

test "SlotStack: top and iterator value editors" {
    const Stack = SlotStack(Cache, StorageManager, u32, u32, .little);

    var manager = StorageManager{};
    var device = try Device.init(std.testing.allocator, 4096);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 8);
    defer cache.deinit();
    var stack = try Stack.init(&cache, &manager, .{});
    defer stack.deinit();

    try stack.push("bottom");
    try stack.push("top");
    var top = try stack.top();
    defer top.deinit();
    var editor = try top.editValue();
    defer editor.deinit();
    (try editor.valueMut())[0] = 'T';
    try std.testing.expectError(error.ValueEditorActive, stack.push("blocked"));
    try editor.finish();
    try std.testing.expectEqualStrings("Top", try top.value());

    var iterator = (try stack.iterator()).?;
    defer iterator.deinit();
    const bottom = (try iterator.next()).?;
    var rollback = (try iterator.editValue()).?;
    (try rollback.valueMut())[0] = 'B';
    rollback.deinit();
    try std.testing.expectEqualStrings("bottom", bottom);

    try stack.pop();
    try stack.pop();
    try std.testing.expect(try stack.isEmpty());
}
