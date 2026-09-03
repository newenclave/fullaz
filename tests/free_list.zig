const std = @import("std");
const fullaz = @import("fullaz");
const FreeList = fullaz.storage.free_list.FreeList;

const page_cache = @import("fullaz").storage.page_cache;
const devices = @import("fullaz").device;

const PAGE = 64;
const FreeListState = fullaz.storage.free_list.State(u32, .little);

test "FreeList: state is exact, byte-aligned, and defaults to maxInt" {
    const state: FreeListState = .{};
    try std.testing.expectEqual(@as(comptime_int, 1), @alignOf(FreeListState));
    try std.testing.expectEqual(@sizeOf(u32), @sizeOf(FreeListState));
    try std.testing.expectEqual(std.math.maxInt(u32), state.root.get());
}

const MemStore = struct {
    const Self = @This();
    pub const Error = error{ StateUnavailable, ReadOnly };
    pub const StateLeaseType = struct {
        pub const Error = MemStore.Error;

        store: *MemStore,

        pub fn data(self: *const @This()) @This().Error![]const u8 {
            return std.mem.asBytes(@as(*const FreeListState, &self.store.state_value));
        }

        pub fn dataMut(self: *@This()) @This().Error![]u8 {
            if (self.store.read_only) {
                return error.ReadOnly;
            }
            return std.mem.asBytes(&self.store.state_value);
        }

        pub fn finish(self: *@This()) void {
            self.store.finish_count += 1;
        }

        pub fn deinit(self: *@This()) void {
            self.store.deinit_count += 1;
        }
    };

    state_value: FreeListState = .{},
    fail_acquire: bool = false,
    read_only: bool = false,
    finish_count: usize = 0,
    deinit_count: usize = 0,

    pub fn state(self: *Self) Error!StateLeaseType {
        if (self.fail_acquire) {
            return error.StateUnavailable;
        }
        return .{ .store = self };
    }
};

test "FreeList: LIFO push/pop, empty behaviour, head persists in the Store" {
    const allocator = std.testing.allocator;

    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    var device = try Device.init(allocator, PAGE);
    defer device.deinit();
    var cache = try Cache.init(&device, allocator, 8);
    defer cache.deinit();

    for (0..8) |i| {
        var ph = try cache.create();
        defer ph.deinit();
        //std.debug.print("Creating page {d}\n", .{i});
        _ = i;
    }

    var store = MemStore{};
    const FL = FreeList(Cache, MemStore, .little);
    var fl = FL.init(&cache, &store);

    // Empty.
    try std.testing.expect(try fl.isEmpty());
    try std.testing.expect((try fl.pop()) == null);

    // LIFO: push 3,5,7 -> pop 7,5,3.
    try fl.push(3);
    try std.testing.expect(!try fl.isEmpty());
    try fl.push(5);
    try fl.push(7);
    try std.testing.expectEqual(@as(?u32, 7), try fl.pop());
    try std.testing.expectEqual(@as(?u32, 5), try fl.pop());
    try std.testing.expectEqual(@as(?u32, 3), try fl.pop());
    try std.testing.expect(try fl.isEmpty());
    try std.testing.expect((try fl.pop()) == null);

    // Interleaved push/pop.
    try fl.push(2);
    try fl.push(4);
    try std.testing.expectEqual(@as(?u32, 4), try fl.pop());
    try fl.push(6);
    try std.testing.expectEqual(@as(?u32, 6), try fl.pop());
    try std.testing.expectEqual(@as(?u32, 2), try fl.pop());
    try std.testing.expect(try fl.isEmpty());

    // The list lives entirely in the Store (FreeList is stateless): a fresh
    // FreeList over the same Store sees the same stack.
    try fl.push(1);
    try fl.push(3);

    var fl2 = FL.init(&cache, &store);
    try std.testing.expectEqual(@as(?u32, 3), try fl2.pop());
    try std.testing.expectEqual(@as(?u32, 1), try fl2.pop());
    try std.testing.expect(try fl2.isEmpty());
    try std.testing.expectEqual(@as(usize, 16), store.finish_count);
    try std.testing.expectEqual(@as(usize, 23), store.deinit_count);
}

test "FreeList: page ID zero is a valid root and writes finish their leases" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    var device = try Device.init(std.testing.allocator, PAGE);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 2);
    defer cache.deinit();
    var page = try cache.create();
    page.deinit();

    var store = MemStore{};
    var fl = FreeList(Cache, MemStore, .little).init(&cache, &store);
    try fl.push(0);
    try std.testing.expectEqual(@as(u32, 0), store.state_value.root.get());
    try std.testing.expect(!try fl.isEmpty());
    try std.testing.expectEqual(@as(?u32, 0), try fl.pop());
    try std.testing.expect(store.state_value.root.isMax());
    try std.testing.expectEqual(@as(usize, 2), store.finish_count);
    try std.testing.expectEqual(@as(usize, 3), store.deinit_count);
}

test "FreeList: failed and read-only state leases are released without finish" {
    const Device = devices.MemoryBlock(u32);
    const Cache = page_cache.PageCache(Device);
    var device = try Device.init(std.testing.allocator, PAGE);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 2);
    defer cache.deinit();
    var page = try cache.create();
    page.deinit();

    var store = MemStore{};
    var fl = FreeList(Cache, MemStore, .little).init(&cache, &store);
    store.fail_acquire = true;
    try std.testing.expectError(error.StateUnavailable, fl.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), store.deinit_count);

    store.fail_acquire = false;
    store.read_only = true;
    try std.testing.expectError(error.ReadOnly, fl.push(0));
    try std.testing.expect(store.state_value.root.isMax());
    try std.testing.expectEqual(@as(usize, 0), store.finish_count);
    try std.testing.expectEqual(@as(usize, 1), store.deinit_count);
}
