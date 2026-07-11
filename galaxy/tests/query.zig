const std = @import("std");
const common = @import("common.zig");

const testing = std.testing;
const Device = common.Device;
const PageCache = common.PageCache;
const G = common.G;
const Collector = common.Collector;

test "galaxy: window query matches a brute-force scan" {
    const alloc = testing.allocator;
    var device = try Device.init(alloc, common.block_size);
    defer device.deinit();
    var cache = try PageCache.init(&device, alloc, common.frames);
    defer cache.deinit();
    var g = try G.format(alloc, &cache, common.block_size, 11, 500.0, 500.0);
    defer g.deinit();

    // Spread stars over a wider region than a single viewport.
    _ = try g.move(.east);
    _ = try g.move(.north);
    _ = try g.move(.east);

    // Every star that exists anywhere near the explored region.
    var all = try Collector.init(alloc);
    defer all.deinit();
    try g.queryBox(0, 0, 1000, 1000, &all, Collector.cb);
    try testing.expect(all.items.items.len > 0);

    // An arbitrary sub-window, not aligned to the viewport.
    const wl: f64 = 498.0;
    const wr: f64 = 507.0;
    const wb: f64 = 501.0;
    const wt: f64 = 512.0;

    var got = try Collector.init(alloc);
    defer got.deinit();
    try g.queryBox(wl, wb, wr, wt, &got, Collector.cb);

    // Brute force: a point star is in the window iff strictly inside it (the
    // R-tree uses half-open overlap for a zero-width box).
    var expected: usize = 0;
    for (all.items.items) |r| {
        if (r.x > wl and r.x < wr and r.y > wb and r.y < wt) expected += 1;
    }
    try testing.expectEqual(expected, got.items.items.len);

    // The actual id sets match, too.
    all.sortById();
    got.sortById();
    var j: usize = 0;
    for (all.items.items) |r| {
        if (r.x > wl and r.x < wr and r.y > wb and r.y < wt) {
            try testing.expectEqual(r.id, got.items.items[j].id);
            j += 1;
        }
    }
}
