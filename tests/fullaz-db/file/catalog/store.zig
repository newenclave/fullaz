const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

const Manager = struct {
    pub const PageId = u32;
    pub const Size = u64;
    pub const Error = error{};

    first: ?PageId = null,
    last: ?PageId = null,
    total: Size = 0,

    pub fn destroyPage(_: *@This(), _: PageId) Error!void {}
    pub fn getTotalSize(self: *const @This()) Error!Size {
        return self.total;
    }
    pub fn setTotalSize(self: *@This(), value: Size) Error!void {
        self.total = value;
    }
    pub fn getFirst(self: *const @This()) Error!?PageId {
        return self.first;
    }
    pub fn setFirst(self: *@This(), value: ?PageId) Error!void {
        self.first = value;
    }
    pub fn getLast(self: *const @This()) Error!?PageId {
        return self.last;
    }
    pub fn setLast(self: *@This(), value: ?PageId) Error!void {
        self.last = value;
    }
};

fn encodeRecord(bytes: []u8, scratch: []u8, revision: u32, name: []const u8) ![]const u8 {
    try fullaz_db.file.catalog_record.format(bytes, scratch, .{
        .component_id = 1,
        .revision = revision,
        .name = name,
        .kind_name = "test.component",
        .component_format_version = 1,
        .metadata_format_version = 1,
        .page_kind_base = 0x0100,
        .page_kind_count = 1,
        .metadata_root_pid = 1,
        .settings_fingerprint = [_]u8{0} ** 32,
        .dependency_ids = &.{},
    }, &.{});
    const byte_len = try fullaz_db.file.catalog_record.encodedByteSize(bytes);
    return bytes[0..byte_len];
}

test "fullaz-db catalog store: appends, loads, and bounds scans" {
    const Device = fullaz.device.MemoryBlock(u32);
    const Cache = fullaz.storage.page_cache.PageCache(Device);
    const Store = fullaz_db.file.CatalogStore(Cache, Manager);

    var device = try Device.init(std.testing.allocator, 512);
    defer device.deinit();
    var cache = try Cache.init(&device, std.testing.allocator, 4);
    defer cache.deinit();
    _ = try device.appendBlock(); // Reserve PID zero for the boot page.
    var manager = Manager{};
    var store = try Store.init(&cache, &manager);
    defer store.deinit();

    var first_bytes: [256]u8 = undefined;
    var first_scratch: [256]u8 = undefined;
    const first = try encodeRecord(&first_bytes, &first_scratch, 1, "first");
    const ref = try store.append(first);

    var loaded = try store.load(ref);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("first", (try loaded.view()).name);

    var iterator = try store.iterator(1);
    defer iterator.deinit();
    const entry = (try iterator.next()).?;
    try std.testing.expectEqual(ref.getPageId(), entry.ref.getPageId());
    try std.testing.expectEqualStrings("first", entry.record.name);
    try std.testing.expect((try iterator.next()) == null);
}
