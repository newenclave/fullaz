const std = @import("std");
const common = @import("common.zig");

const testing = std.testing;
const Device = common.Device;
const PageCache = common.PageCache;
const G = common.G;
const constants = common.galaxy.constants;

test "galaxy: renderGrid centers the player and plots stars" {
    const alloc = testing.allocator;
    var device = try Device.init(alloc, common.block_size);
    defer device.deinit();
    var cache = try PageCache.init(&device, alloc, common.frames);
    defer cache.deinit();
    var g = try G.format(alloc, &cache, common.block_size, 21, 600.9, 601.9);
    defer g.deinit();

    var grid: [constants.map_rows * constants.map_cols]u21 = undefined;
    const count = try g.renderGrid(&grid);

    try testing.expect(count > 0);

    const center = (constants.map_rows / 2) * constants.map_cols + (constants.map_cols / 2);
    try testing.expectEqual(@as(u21, '@'), grid[center]);

    var glyphs: usize = 0;
    for (grid) |ch| {
        if (ch != ' ' and ch != '@') glyphs += 1;
    }
    try testing.expect(glyphs > 0);
}
