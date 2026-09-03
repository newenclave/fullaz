const std = @import("std");
const fullaz = @import("fullaz");

const State = fullaz.storage.virtual_page_map.CowPagedState(u32, u32);
const StateManager = struct {
    const Self = @This();

    pub const Error = error{};
    pub const StateLeaseType = struct {
        pub const Error = error{};

        value: *State,

        pub fn data(self: *const @This()) @This().Error![]const u8 {
            return std.mem.asBytes(@as(*const State, self.value));
        }

        pub fn dataMut(self: *@This()) @This().Error![]u8 {
            return std.mem.asBytes(self.value);
        }

        pub fn finish(_: *@This()) void {}
        pub fn deinit(_: *@This()) void {}
    };

    value: *State,

    pub fn state(self: *Self) Error!StateLeaseType {
        return .{ .value = self.value };
    }
};

fn setState(state: *State, snapshot: anytype) void {
    state.root_page_id.set(snapshot.root_page_id orelse std.math.maxInt(u32));
    state.root_level.set(snapshot.root_level);
    state.next_virtual_page_id.set(snapshot.next_virtual_page_id);
}

test "CowPaged keeps old snapshots while remapping a VID" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Cache = fullaz.storage.page_cache.PageCache(Device);
    const Map = fullaz.storage.virtual_page_map.CowPaged(Cache, StateManager, u32);

    var device = try Device.init(std.testing.allocator, 512);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 16);
    defer cache.deinit();
    var state: State = .{};
    var manager = StateManager{ .value = &state };
    var map = try Map.init(&cache, &manager, {});
    defer map.deinit();

    var first_cache_batch = try cache.begin();
    var first_map_batch = try map.begin();
    var first_data = try cache.create();
    const first_page_id = try first_data.pid();
    first_data.deinit();
    const virtual_page_id = try map.set(first_page_id);
    const first_snapshot = map.currentSnapshot();
    first_map_batch.commit();
    try first_cache_batch.commit();

    try std.testing.expectEqual(first_page_id, try map.get(virtual_page_id));

    var second_cache_batch = try cache.begin();
    var second_map_batch = try map.begin();
    var second_data = try cache.create();
    const second_page_id = try second_data.pid();
    second_data.deinit();
    try map.remap(virtual_page_id, second_page_id);
    const second_snapshot = map.currentSnapshot();
    second_map_batch.commit();
    try second_cache_batch.commit();

    try std.testing.expectEqual(second_page_id, try map.get(virtual_page_id));
    try std.testing.expect(first_snapshot.root_page_id.? != second_snapshot.root_page_id.?);

    var old_state: State = .{};
    setState(&old_state, first_snapshot);
    var old_manager = StateManager{ .value = &old_state };
    var old_map = try Map.init(&cache, &old_manager, {});
    defer old_map.deinit();
    try std.testing.expectEqual(first_page_id, try old_map.get(virtual_page_id));
}

test "CowPaged restores its snapshot before an append-only rollback" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Cache = fullaz.storage.page_cache.PageCache(Device);
    const Map = fullaz.storage.virtual_page_map.CowPaged(Cache, StateManager, u32);

    var device = try Device.init(std.testing.allocator, 512);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 16);
    defer cache.deinit();
    var state: State = .{};
    var manager = StateManager{ .value = &state };
    var map = try Map.init(&cache, &manager, {});
    defer map.deinit();

    var cache_batch = try cache.begin();
    var map_batch = try map.begin();
    var data = try cache.create();
    const page_id = try data.pid();
    data.deinit();
    const virtual_page_id = try map.set(page_id);
    map_batch.commit();
    try cache_batch.commit();

    const committed = map.currentSnapshot();
    const committed_page_count = cache.pageCount();
    var rollback_cache_batch = try cache.begin();
    var rollback_map_batch = try map.begin();
    var replacement = try cache.create();
    const replacement_page_id = try replacement.pid();
    replacement.deinit();
    try map.remap(virtual_page_id, replacement_page_id);
    rollback_map_batch.discard();
    try rollback_cache_batch.discard();

    try std.testing.expectEqualDeep(committed, map.currentSnapshot());
    try std.testing.expectEqual(committed_page_count, cache.pageCount());
    try std.testing.expectEqual(page_id, try map.get(virtual_page_id));
}

test "CowPaged mutates transaction-private nodes without another fork" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Cache = fullaz.storage.page_cache.PageCache(Device);
    const Map = fullaz.storage.virtual_page_map.CowPaged(Cache, StateManager, u32);

    var device = try Device.init(std.testing.allocator, 512);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 16);
    defer cache.deinit();
    var state: State = .{};
    var manager = StateManager{ .value = &state };
    var map = try Map.init(&cache, &manager, {});
    defer map.deinit();

    var cache_batch = try cache.begin();
    var map_batch = try map.begin();
    var first_data = try cache.create();
    const first_page_id = try first_data.pid();
    first_data.deinit();
    const first_virtual_page_id = try map.set(first_page_id);
    var second_data = try cache.create();
    const second_page_id = try second_data.pid();
    second_data.deinit();
    const second_virtual_page_id = try map.set(second_page_id);

    // Two data pages plus one shared, transaction-private mapping leaf.
    try std.testing.expectEqual(@as(usize, 3), cache.pageCount());
    try std.testing.expectEqual(first_page_id, try map.get(first_virtual_page_id));
    try std.testing.expectEqual(second_page_id, try map.get(second_virtual_page_id));
    map_batch.commit();
    try cache_batch.commit();
}
