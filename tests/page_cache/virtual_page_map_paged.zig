const std = @import("std");
const fullaz = @import("fullaz");

fn TestStateManager(comptime StateLength: usize) type {
    return struct {
        const Self = @This();

        pub const PageId = u32;
        pub const Error = error{};
        pub const StateLeaseType = StateLease;

        pub const StateLease = struct {
            const LeaseError = error{};

            pub const Error = LeaseError;

            bytes: []u8,

            pub fn data(self: *const @This()) LeaseError![]const u8 {
                return self.bytes;
            }

            pub fn dataMut(self: *@This()) LeaseError![]u8 {
                return self.bytes;
            }

            pub fn deinit(_: *@This()) void {}
        };

        state_bytes: [StateLength]u8 = undefined,
        destroyed_pages: usize = 0,

        pub fn state(self: *Self) Error!StateLease {
            return .{ .bytes = &self.state_bytes };
        }

        pub fn destroyPage(self: *Self, _: PageId) Error!void {
            self.destroyed_pages += 1;
        }
    };
}

test "VirtualPageMap paged formats and opens typed state" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Cache = fullaz.storage.page_cache.PageCache(Device);
    const Manager = TestStateManager(128);
    const Map = fullaz.storage.virtual_page_map.Paged(Cache, Manager, u32);

    var device = try Device.init(std.testing.allocator, 256);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 16);
    defer cache.deinit();
    var manager = Manager{};
    @memset(&manager.state_bytes, 0xaa);

    var map = try Map.format(&cache, &manager, .{
        .virtual_to_physical = .{ .leaf = 1, .inode = 2 },
        .physical_to_virtual = .{ .leaf = 3, .inode = 4 },
    });
    {
        var cache_batch = try cache.begin();
        var map_batch = try map.begin();
        const virtual_page_id = try map.set(41);
        try std.testing.expectEqual(@as(u32, 0), virtual_page_id);
        try std.testing.expectEqual(virtual_page_id, try map.set(41));
        try std.testing.expectEqual(@as(u32, 41), try map.get(virtual_page_id));
        try std.testing.expectEqual(@as(usize, 1), map.pageCount());
        try cache_batch.commit();
        map_batch.commit();
    }

    var opened = try Map.open(&cache, &manager, .{
        .virtual_to_physical = .{ .leaf = 1, .inode = 2 },
        .physical_to_virtual = .{ .leaf = 3, .inode = 4 },
    });
    try std.testing.expectEqual(@as(u32, 41), try opened.get(0));
    {
        var cache_batch = try cache.begin();
        var map_batch = try opened.begin();
        try opened.remap(0, 99);
        try std.testing.expectEqual(@as(u32, 99), try opened.get(0));
        try cache_batch.commit();
        map_batch.commit();
    }
    try std.testing.expectEqual(@as(u32, 99), try opened.get(0));
    try std.testing.expect(manager.destroyed_pages > 0);
    {
        var cache_batch = try cache.begin();
        var map_batch = try opened.begin();
        try std.testing.expectEqual(@as(u32, 1), try opened.set(123));
        map_batch.discard();
        try cache_batch.discard();
    }
    try std.testing.expectEqual(@as(usize, 1), opened.pageCount());
    try std.testing.expectEqual(@as(u32, 99), try opened.get(0));
    try std.testing.expectError(error.VirtualPageNotMapped, opened.get(1));
    opened.deinit();
    map.deinit();
    try std.testing.expect(Map.state_size <= manager.state_bytes.len);
}

test "VirtualPageMap paged mutates outside an owned batch" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Cache = fullaz.storage.page_cache.PageCache(Device);
    const Manager = TestStateManager(128);
    const Map = fullaz.storage.virtual_page_map.Paged(Cache, Manager, u32);
    const settings = Map.Settings{
        .virtual_to_physical = .{ .leaf = 1, .inode = 2 },
        .physical_to_virtual = .{ .leaf = 3, .inode = 4 },
    };

    var device = try Device.init(std.testing.allocator, 256);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 16);
    defer cache.deinit();
    var manager = Manager{};
    var map = try Map.format(&cache, &manager, settings);
    defer map.deinit();

    const virtual_page_id = try map.set(41);
    try map.remap(virtual_page_id, 73);
    try std.testing.expect(!map.transactionActive());
    try std.testing.expectEqual(@as(u32, 73), try map.get(virtual_page_id));
    try cache.flushAll();

    var opened = try Map.open(&cache, &manager, settings);
    defer opened.deinit();
    try std.testing.expectEqual(@as(u32, 73), try opened.get(virtual_page_id));
}

test "VirtualPageMap paged rejects invalid state and settings" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Cache = fullaz.storage.page_cache.PageCache(Device);
    const Manager = TestStateManager(128);
    const Map = fullaz.storage.virtual_page_map.Paged(Cache, Manager, u32);

    var device = try Device.init(std.testing.allocator, 256);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 16);
    defer cache.deinit();
    var manager = Manager{};

    try std.testing.expectError(Map.Error.InvalidSettings, Map.format(&cache, &manager, .{
        .virtual_to_physical = .{ .leaf = 1, .inode = 2 },
        .physical_to_virtual = .{ .leaf = 2, .inode = 4 },
    }));

    var map = try Map.format(&cache, &manager, .{
        .virtual_to_physical = .{ .leaf = 1, .inode = 2 },
        .physical_to_virtual = .{ .leaf = 3, .inode = 4 },
    });
    map.deinit();
    manager.state_bytes[0] = 0;
    try std.testing.expectError(Map.Error.InvalidState, Map.open(&cache, &manager, .{
        .virtual_to_physical = .{ .leaf = 1, .inode = 2 },
        .physical_to_virtual = .{ .leaf = 3, .inode = 4 },
    }));
}

test "VirtualPageMap paged rejects a short state region" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Cache = fullaz.storage.page_cache.PageCache(Device);
    const Manager = TestStateManager(1);
    const Map = fullaz.storage.virtual_page_map.Paged(Cache, Manager, u32);

    var device = try Device.init(std.testing.allocator, 256);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 16);
    defer cache.deinit();
    var manager = Manager{};

    try std.testing.expectError(Map.Error.StateTooSmall, Map.format(&cache, &manager, .{
        .virtual_to_physical = .{ .leaf = 1, .inode = 2 },
        .physical_to_virtual = .{ .leaf = 3, .inode = 4 },
    }));
}
