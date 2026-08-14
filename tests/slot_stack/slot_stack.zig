const std = @import("std");
const fullaz = @import("fullaz");

const Device = fullaz.device.MemoryBlock(u32);
const Cache = fullaz.storage.page_cache.PageCache(Device);
const SlotStack = fullaz.storage.slot_stack.SlotStack;

const StorageManager = struct {
    pub const PageId = u32;
    pub const Size = u32;
    pub const Error = error{};

    first_page_id: ?PageId = null,
    last_page_id: ?PageId = null,
    total_size: Size = 0,

    pub fn destroyPage(_: *@This(), _: PageId) Error!void {}

    pub fn getFirst(self: *const @This()) Error!?PageId {
        return self.first_page_id;
    }

    pub fn setFirst(self: *@This(), page_id: ?PageId) Error!void {
        self.first_page_id = page_id;
    }

    pub fn getLast(self: *const @This()) Error!?PageId {
        return self.last_page_id;
    }

    pub fn setLast(self: *@This(), page_id: ?PageId) Error!void {
        self.last_page_id = page_id;
    }

    pub fn getTotalSize(self: *const @This()) Error!Size {
        return self.total_size;
    }

    pub fn setTotalSize(self: *@This(), size: Size) Error!void {
        self.total_size = size;
    }
};

test "SlotStack: push, top, pop, and iterate" {
    const Stack = SlotStack(Cache, StorageManager, .little);

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
