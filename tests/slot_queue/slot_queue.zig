const std = @import("std");
const fullaz = @import("fullaz");

const Device = fullaz.device.MemoryBlock(u32);
const Cache = fullaz.storage.page_cache.PageCache(Device);
const SlotQueue = fullaz.storage.slot_queue.SlotQueue;

const RootOnlyStorageManager = struct {
    pub const PageId = u32;
    pub const Size = u32;
    pub const Error = error{};

    first_page_id: ?PageId = null,
    total_size: Size = 0,

    pub fn destroyPage(_: *@This(), _: PageId) Error!void {}

    pub fn getFirst(self: *const @This()) Error!?PageId {
        return self.first_page_id;
    }

    pub fn setFirst(self: *@This(), page_id: ?PageId) Error!void {
        self.first_page_id = page_id;
    }

    pub fn getTotalSize(self: *const @This()) Error!Size {
        return self.total_size;
    }

    pub fn setTotalSize(self: *@This(), size: Size) Error!void {
        self.total_size = size;
    }
};

test "SlotQueue: enqueue, front, dequeue, and iterate" {
    const Queue = SlotQueue(Cache, RootOnlyStorageManager, .little);

    var manager = RootOnlyStorageManager{};
    var device = try Device.init(std.testing.allocator, 4096);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 8);
    defer cache.deinit();
    var queue = try Queue.init(&cache, &manager, .{});
    defer queue.deinit();

    try std.testing.expectError(error.EmptySet, queue.front());
    try std.testing.expectError(error.EmptySet, queue.dequeue());

    try queue.enqueue("first");
    try queue.enqueue("second");
    try queue.enqueue("third");
    try std.testing.expectEqual(@as(usize, 3), try queue.size());

    var front = try queue.front();
    defer front.deinit();
    try std.testing.expectEqualStrings("first", try front.value());

    var iterator = (try queue.iterator()).?;
    defer iterator.deinit();
    try std.testing.expectEqualStrings("first", (try iterator.next()).?);
    try std.testing.expectEqualStrings("second", (try iterator.next()).?);
    try std.testing.expectEqualStrings("third", (try iterator.next()).?);
    try std.testing.expect((try iterator.next()) == null);

    try queue.dequeue();
    try queue.dequeue();
    var remaining = try queue.front();
    defer remaining.deinit();
    try std.testing.expectEqualStrings("third", try remaining.value());
    try queue.dequeue();
    try std.testing.expect(try queue.isEmpty());
    try std.testing.expectError(error.EmptySet, queue.dequeue());
}

test "SlotQueue: front and iterator value editors" {
    const Queue = SlotQueue(Cache, RootOnlyStorageManager, .little);

    var manager = RootOnlyStorageManager{};
    var device = try Device.init(std.testing.allocator, 4096);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 8);
    defer cache.deinit();
    var queue = try Queue.init(&cache, &manager, .{});
    defer queue.deinit();

    try queue.enqueue("front");
    var front = try queue.front();
    defer front.deinit();
    var editor = try front.editValue();
    defer editor.deinit();
    (try editor.valueMut())[0] = 'F';
    try std.testing.expectError(error.ValueEditorActive, queue.enqueue("blocked"));
    try editor.finish();
    try std.testing.expectEqualStrings("Front", try front.value());

    var iterator = (try queue.iterator()).?;
    defer iterator.deinit();
    const current = (try iterator.next()).?;
    var rollback = (try iterator.editValue()).?;
    (try rollback.valueMut())[1] = 'X';
    rollback.deinit();
    try std.testing.expectEqualStrings("Front", current);
}
