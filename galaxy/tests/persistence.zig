const std = @import("std");
const common = @import("common.zig");

const testing = std.testing;
const Device = common.Device;
const PageCache = common.PageCache;
const G = common.G;
const Collector = common.Collector;

test "galaxy: save + reopen restores the world and does not regenerate" {
    const alloc = testing.allocator;
    var device = try Device.init(alloc, common.block_size);
    defer device.deinit();

    var seed0: u64 = 0;
    var counter0: u32 = 0;
    var px0: f64 = 0;
    var py0: f64 = 0;
    var stars0: usize = 0;

    // Session 1: create, explore, save, flush to the device.
    {
        var cache = try PageCache.init(&device, alloc, common.frames);
        defer cache.deinit();
        var g = try G.format(alloc, &cache, common.block_size, 99, 800.0, 800.0);
        defer g.deinit();

        _ = try g.move(.east);
        _ = try g.move(.north);

        seed0 = g.seed;
        counter0 = g.star_counter;
        px0 = g.px;
        py0 = g.py;

        var all = try Collector.init(alloc);
        defer all.deinit();
        try g.queryBox(0, 0, 2000, 2000, &all, Collector.cb);
        stars0 = all.items.items.len;

        try g.save();
        try cache.flushAll();
    }

    // Session 2: a brand new cache over the same device.
    {
        var cache = try PageCache.init(&device, alloc, common.frames);
        defer cache.deinit();
        var g = try G.open(alloc, &cache, common.block_size);
        defer g.deinit();

        try testing.expectEqual(seed0, g.seed);
        try testing.expectEqual(counter0, g.star_counter);
        try testing.expectEqual(px0, g.px);
        try testing.expectEqual(py0, g.py);

        var all = try Collector.init(alloc);
        defer all.deinit();
        try g.queryBox(0, 0, 2000, 2000, &all, Collector.cb);
        try testing.expectEqual(stars0, all.items.items.len);

        // Standing on the restored spot, nothing regenerates.
        try testing.expectEqual(@as(usize, 0), try g.reveal());
    }
}
