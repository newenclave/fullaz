const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

const Manager = struct {
    pub const PageId = u32;
    pub const Error = error{};
    pub const StateLeaseType = struct {
        const Self = @This();

        pub const Error = Manager.Error;

        manager: *Manager,
        bytes: [@sizeOf(PageId)]u8,

        pub fn data(self: *const Self) error{}![]const u8 {
            return &self.bytes;
        }

        pub fn dataMut(self: *Self) error{}![]u8 {
            return &self.bytes;
        }

        pub fn finish(self: *Self) void {
            const root = std.mem.readInt(PageId, &self.bytes, .little);
            self.manager.root = if (root == std.math.maxInt(PageId)) null else root;
        }

        pub fn deinit(_: *Self) void {}
    };

    root: ?PageId = null,

    pub fn state(self: *@This()) Error!StateLeaseType {
        var lease: StateLeaseType = .{
            .manager = self,
            .bytes = undefined,
        };
        std.mem.writeInt(PageId, &lease.bytes, self.root orelse std.math.maxInt(PageId), .little);
        return lease;
    }

    pub fn destroyPage(_: *@This(), _: PageId) Error!void {}
};

test "fullaz-db catalog name index: maps exact names to component IDs" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Cache = fullaz.storage.page_cache.PageCache(Device);
    const Index = fullaz_db.file.CatalogNameIndex(Cache, Manager);

    var device = try Device.init(std.testing.allocator, 1024);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 16);
    defer cache.deinit();
    _ = try device.appendBlock(); // Reserve PID zero for the boot page.
    var manager = Manager{};
    var index = try Index.init(&cache, &manager);
    defer index.deinit();

    try index.set("index", 1);
    try index.set("index", 2);
    try index.set("jobs", 3);

    try std.testing.expectEqual(@as(?u64, 2), try index.get("index"));
    try std.testing.expectEqual(@as(?u64, 3), try index.get("jobs"));
    try std.testing.expectEqual(@as(?u64, null), try index.get("missing"));
    try std.testing.expectError(error.InvalidComponentName, index.get(""));
    try std.testing.expectError(error.InvalidComponentId, index.set("bad", 0));

    try std.testing.expect(try index.remove("index"));
    try std.testing.expectEqual(@as(?u64, null), try index.get("index"));
    try std.testing.expect(!try index.remove("index"));
    try index.set("index", 4);
    try std.testing.expectEqual(@as(?u64, 4), try index.get("index"));
}
