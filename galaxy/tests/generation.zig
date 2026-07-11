const std = @import("std");
const common = @import("common.zig");

const testing = std.testing;
const Device = common.Device;
const PageCache = common.PageCache;
const G = common.G;
const Collector = common.Collector;

test "galaxy: spawn generates stars in the viewport" {
    const alloc = testing.allocator;
    var device = try Device.init(alloc, common.block_size);
    defer device.deinit();
    var cache = try PageCache.init(&device, alloc, common.frames);
    defer cache.deinit();
    var g = try G.format(alloc, &cache, common.block_size, 42, 600.9, 601.9);
    defer g.deinit();

    var c = try Collector.init(alloc);
    defer c.deinit();
    try g.queryViewport(&c, Collector.cb);

    try testing.expect(c.items.items.len > 0);
    try testing.expect(g.star_counter > 0);
}

test "galaxy: same seed + spawn produces identical stars" {
    const alloc = testing.allocator;

    var da = try Device.init(alloc, common.block_size);
    defer da.deinit();
    var ca = try PageCache.init(&da, alloc, common.frames);
    defer ca.deinit();
    var ga = try G.format(alloc, &ca, common.block_size, 7, 100.0, 200.0);
    defer ga.deinit();
    var a = try Collector.init(alloc);
    defer a.deinit();
    try ga.queryViewport(&a, Collector.cb);

    var db = try Device.init(alloc, common.block_size);
    defer db.deinit();
    var cbk = try PageCache.init(&db, alloc, common.frames);
    defer cbk.deinit();
    var gb = try G.format(alloc, &cbk, common.block_size, 7, 100.0, 200.0);
    defer gb.deinit();
    var b = try Collector.init(alloc);
    defer b.deinit();
    try gb.queryViewport(&b, Collector.cb);

    try testing.expectEqual(ga.star_counter, gb.star_counter);
    try testing.expectEqual(a.items.items.len, b.items.items.len);

    a.sortById();
    b.sortById();
    for (a.items.items, b.items.items) |ra, rb| {
        try testing.expectEqual(ra.id, rb.id);
        try testing.expectEqual(ra.x, rb.x);
        try testing.expectEqual(ra.y, rb.y);
    }
}

test "galaxy: re-revealing the same viewport creates nothing" {
    const alloc = testing.allocator;
    var device = try Device.init(alloc, common.block_size);
    defer device.deinit();
    var cache = try PageCache.init(&device, alloc, common.frames);
    defer cache.deinit();
    var g = try G.format(alloc, &cache, common.block_size, 5, 0.0, 0.0);
    defer g.deinit();

    try testing.expectEqual(@as(usize, 0), try g.reveal());
}

test "galaxy: moving reveals new cells without duplicating old ones" {
    const alloc = testing.allocator;
    var device = try Device.init(alloc, common.block_size);
    defer device.deinit();
    var cache = try PageCache.init(&device, alloc, common.frames);
    defer cache.deinit();
    var g = try G.format(alloc, &cache, common.block_size, 3, 0.0, 0.0);
    defer g.deinit();

    var before = try Collector.init(alloc);
    defer before.deinit();
    try g.queryBox(-100, -100, 100, 100, &before, Collector.cb);
    const c0 = before.items.items.len;

    // Fly east across many new columns of cells.
    var total_created: usize = 0;
    for (0..8) |_| total_created += try g.move(.east);
    try testing.expect(total_created > 0);

    var after = try Collector.init(alloc);
    defer after.deinit();
    try g.queryBox(-100, -100, 100, 100, &after, Collector.cb);
    // The tree grew by exactly the newly created stars; nothing duplicated.
    try testing.expectEqual(c0 + total_created, after.items.items.len);

    // Flying back west revisits only already-covered cells: nothing new.
    var back_created: usize = 0;
    for (0..8) |_| back_created += try g.move(.west);
    try testing.expectEqual(@as(usize, 0), back_created);

    var back = try Collector.init(alloc);
    defer back.deinit();
    try g.queryBox(-100, -100, 100, 100, &back, Collector.cb);
    try testing.expectEqual(after.items.items.len, back.items.items.len);
}
