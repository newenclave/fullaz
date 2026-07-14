const std = @import("std");
const common = @import("common.zig");

const testing = std.testing;
const Device = common.Device;
const PageCache = common.PageCache;
const Collector = common.Collector;

fn revealStars(comptime GameT: type, alloc: std.mem.Allocator, out: *Collector) !u32 {
    var device = try Device.init(alloc, common.block_size);
    defer device.deinit();
    var cache = try PageCache.init(&device, alloc, common.frames);
    defer cache.deinit();
    var g = try GameT.format(alloc, &cache, common.block_size, 1234, 500.0, 500.0);
    defer g.deinit();
    try g.queryViewport(out, Collector.cb);
    out.sortById();
    return g.star_counter;
}

test "galaxy: Linear strategy generates queryable stars" {
    const alloc = testing.allocator;
    var c = try Collector.init(alloc);
    defer c.deinit();
    const total = try revealStars(common.GLinear, alloc, &c);
    try testing.expect(total > 0);
    try testing.expect(c.items.items.len > 0);
}

test "galaxy: strategy does not change the star set (same seed)" {
    const alloc = testing.allocator;

    var guttman = try Collector.init(alloc);
    defer guttman.deinit();
    const t_g = try revealStars(common.GGuttman, alloc, &guttman);

    var linear = try Collector.init(alloc);
    defer linear.deinit();
    const t_l = try revealStars(common.GLinear, alloc, &linear);

    var hybrid = try Collector.init(alloc);
    defer hybrid.deinit();
    const t_h = try revealStars(common.GHybrid, alloc, &hybrid);

    try testing.expectEqual(t_g, t_l);
    try testing.expectEqual(t_g, t_h);
    try testing.expectEqual(guttman.items.items.len, linear.items.items.len);
    try testing.expectEqual(guttman.items.items.len, hybrid.items.items.len);

    for (guttman.items.items, linear.items.items, hybrid.items.items) |rg, rl, rh| {
        try testing.expectEqual(rg.id, rl.id);
        try testing.expectEqual(rg.id, rh.id);
        try testing.expectEqual(rg.x, rl.x);
        try testing.expectEqual(rg.x, rh.x);
        try testing.expectEqual(rg.y, rl.y);
        try testing.expectEqual(rg.y, rh.y);
    }
}
