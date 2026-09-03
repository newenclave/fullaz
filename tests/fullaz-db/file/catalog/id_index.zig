const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");
const RadixState = fullaz.radix_tree.models.paged.State(u32, .little);

const Manager = struct {
    pub const PageId = u32;
    pub const Error = error{};
    pub const StateLeaseType = struct {
        pub const Error = Manager.Error;

        value: *RadixState,

        pub fn data(self: *const @This()) @This().Error![]const u8 {
            return std.mem.asBytes(@as(*const RadixState, self.value));
        }

        pub fn dataMut(self: *@This()) @This().Error![]u8 {
            return std.mem.asBytes(self.value);
        }

        pub fn finish(_: *@This()) void {}
        pub fn deinit(_: *@This()) void {}
    };

    state_value: RadixState = .{},

    pub fn state(self: *@This()) Error!StateLeaseType {
        return .{ .value = &self.state_value };
    }

    pub fn destroyPage(_: *@This(), _: PageId) Error!void {}
};

test "fullaz-db catalog ID index: maps component IDs to catalog references" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Cache = fullaz.storage.page_cache.PageCache(Device);
    const Index = fullaz_db.file.CatalogIdIndex(Cache, Manager);

    var device = try Device.init(std.testing.allocator, 1024);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 16);
    defer cache.deinit();
    _ = try device.appendBlock(); // Reserve PID zero for the boot page.
    var manager = Manager{};
    var index = try Index.init(&cache, &manager);
    defer index.deinit();

    const first = try fullaz_db.file.CatalogRef.init(12, 3, 1);
    const replacement = try fullaz_db.file.CatalogRef.init(19, 7, 2);
    try index.set(42, first);
    try index.set(42, replacement);

    const found = (try index.get(42)).?;
    try std.testing.expectEqual(@as(u64, 19), found.getPageId());
    try std.testing.expectEqual(@as(u16, 7), found.getSlotId());
    try std.testing.expectEqual(@as(u32, 2), found.getRecordRevision());
    try std.testing.expect((try index.get(99)) == null);
    try std.testing.expect((try index.get(0)) == null);
}
