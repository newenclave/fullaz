const std = @import("std");
const pages = @import("fullaz").pages;

test "Pages: empty memory database owns a pointer-stable backend" {
    const Schema = pages.Schema(.{ .page_id = u32 });
    const Db = pages.MemoryDatabase(Schema);

    var database = try Db.init(std.testing.allocator, .{
        .page_size = 4096,
        .cache_frames = 4,
    });
    const core_address = database.core_;
    const cache_address = &database.core_.cache;
    const device_address = &database.core_.device;

    var moved = database;
    database = undefined;
    defer moved.deinit();

    try std.testing.expect(moved.core_ == core_address);
    try std.testing.expect(moved.core_.backend.cache() == cache_address);
    try std.testing.expect(moved.core_.raw_cache.device == device_address);
    try std.testing.expectEqual(@as(usize, 4096), moved.core_.backend.cache().pageSize());
}

test "Pages: memory database rejects zero cache frames" {
    const Schema = pages.Schema(.{ .page_id = u32 });
    const Db = pages.MemoryDatabase(Schema);

    try std.testing.expectError(
        error.InvalidCacheFrames,
        Db.init(std.testing.allocator, .{
            .page_size = 4096,
            .cache_frames = 0,
        }),
    );
}
