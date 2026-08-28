const std = @import("std");
const fullaz = @import("fullaz");

test "VirtualPageMap memory assigns dense stable virtual IDs" {
    const Map = fullaz.storage.virtual_page_map.Memory(u32, u32);

    var map = Map.init(std.testing.allocator);
    defer map.deinit();

    try std.testing.expectEqual(@as(u32, 0), try map.set(41));
    try std.testing.expectEqual(@as(u32, 1), try map.set(73));
    try std.testing.expectEqual(@as(u32, 0), try map.set(41));
    try std.testing.expectEqual(@as(usize, 2), map.pageCount());
    try std.testing.expectEqual(@as(u32, 41), try map.get(0));
    try std.testing.expectEqual(@as(u32, 73), try map.get(1));
    try std.testing.expectError(error.VirtualPageNotMapped, map.get(2));
}

test "VirtualPageMap memory remaps without physical aliases" {
    const Map = fullaz.storage.virtual_page_map.Memory(u32, u32);

    var map = Map.init(std.testing.allocator);
    defer map.deinit();

    const first = try map.set(41);
    const second = try map.set(73);
    try map.remap(first, 99);

    try std.testing.expectEqual(@as(u32, 99), try map.get(first));
    try std.testing.expectEqual(@as(u32, 73), try map.get(second));
    try std.testing.expectError(error.PhysicalPageAlreadyMapped, map.remap(first, 73));
    try std.testing.expectEqual(@as(u32, 2), try map.set(41));
}

test "VirtualPageMap memory reserves the virtual nil sentinel" {
    const Map = fullaz.storage.virtual_page_map.Memory(u32, u2);

    var map = Map.init(std.testing.allocator);
    defer map.deinit();

    try std.testing.expectEqual(@as(u2, 0), try map.set(10));
    try std.testing.expectEqual(@as(u2, 1), try map.set(20));
    try std.testing.expectEqual(@as(u2, 2), try map.set(30));
    try std.testing.expectError(error.PageIdExhausted, map.prepareSet());
    try std.testing.expectError(error.PageIdExhausted, map.set(40));
}

test "VirtualPageMap memory discards set and remap changes" {
    const Map = fullaz.storage.virtual_page_map.Memory(u32, u32);

    var map = Map.init(std.testing.allocator);
    defer map.deinit();

    const first = try map.set(10);
    var batch = try map.begin();
    _ = try map.set(20);
    try map.remap(first, 30);
    batch.discard();

    try std.testing.expect(!map.transactionActive());
    try std.testing.expectEqual(@as(usize, 1), map.pageCount());
    try std.testing.expectEqual(@as(u32, 10), try map.get(first));
    try std.testing.expectError(error.VirtualPageNotMapped, map.get(1));
}

test "VirtualPageMap memory commits set and remap changes" {
    const Map = fullaz.storage.virtual_page_map.Memory(u32, u32);

    var map = Map.init(std.testing.allocator);
    defer map.deinit();

    const first = try map.set(10);
    var batch = try map.begin();
    const second = try map.set(20);
    try map.remap(first, 30);
    batch.commit();

    try std.testing.expect(!map.transactionActive());
    try std.testing.expectEqual(@as(usize, 2), map.pageCount());
    try std.testing.expectEqual(@as(u32, 30), try map.get(first));
    try std.testing.expectEqual(@as(u32, 20), try map.get(second));
}

test "VirtualPageMap memory reserves before changing mappings" {
    const Map = fullaz.storage.virtual_page_map.Memory(u32, u32);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var map = Map.init(failing.allocator());
    defer map.deinit();

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, map.prepareSet());
    try std.testing.expectEqual(@as(usize, 0), map.pageCount());
}
