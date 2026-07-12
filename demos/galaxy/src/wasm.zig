const std = @import("std");
const fullaz = @import("fullaz");
const galaxy = @import("galaxy");

const constants = galaxy.constants;
const Star = galaxy.starfield.Star;

const Device = fullaz.device.MemoryBlock(u32);
const PageCache = fullaz.storage.page_cache.PageCache(Device);
const G = galaxy.Galaxy(PageCache);
const Key = G.KeyType;

// Freestanding wasm has no default panic handler (the std one needs the OS).
// Trap on panic — the JS side sees the instance abort.
pub const panic = std.debug.FullPanic(struct {
    fn f(_: []const u8, _: ?usize) noreturn {
        @trap();
    }
}.f);

// wasm is single-threaded, so global state is fine. A proper growing allocator
// (backed by @wasmMemoryGrow) — the "proper allocator" a browser build needs.
const gpa = std.heap.wasm_allocator;

var device: Device = undefined;
var cache: PageCache = undefined;
var game: G = undefined;
var ready: bool = false;

// Filled by snapshot(): per visible star, three f32s — normalized x (0..1,
// left→right), normalized y (0..1, bottom→top), brightness (0..1). JS reads this
// straight out of the wasm linear memory and draws it.
const max_stars = 4096;
var stars_buf: [max_stars * 3]f32 = undefined;
var star_count: usize = 0;

fn deriveSpawn(seed: u64) [2]f64 {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x9e3779b97f4a7c15);
    const r = prng.random();
    return .{ r.float(f64) * 1.0e6, r.float(f64) * 1.0e6 };
}

fn teardown() void {
    if (!ready) return;
    game.deinit();
    cache.deinit();
    device.deinit();
    ready = false;
}

// Create a fresh galaxy from a seed (u32 is plenty of worlds and avoids i64/JS
// BigInt friction). Spawn is derived from the seed, so the world is reproducible.
export fn init(seed: u32) void {
    teardown();
    device = Device.init(gpa, constants.default_block_size) catch @trap();
    cache = PageCache.init(&device, gpa, constants.cache_frames) catch @trap();
    const spawn = deriveSpawn(seed);
    game = G.format(gpa, &cache, @intCast(constants.default_block_size), seed, spawn[0], spawn[1]) catch @trap();
    ready = true;
    snapshot();
}

// Fly one step; returns how many new stars were generated in the revealed space.
export fn move(dir: u32) u32 {
    if (!ready) return 0;
    const d: galaxy.Direction = switch (dir) {
        0 => .north,
        1 => .south,
        2 => .east,
        else => .west,
    };
    const created = game.move(d) catch return 0;
    snapshot();
    return @intCast(created);
}

// Free pan by a world-space delta (from mouse/touch drag on the JS side).
export fn panBy(dx: f64, dy: f64) u32 {
    if (!ready) return 0;
    const created = game.moveBy(dx, dy) catch return 0;
    snapshot();
    return @intCast(created);
}

const Collector = struct {
    lx: f64,
    ly: f64,
    vw: f64,
    vh: f64,

    fn cb(self: *Collector, mbr: Key, value: []const u8) anyerror!void {
        if (star_count >= max_stars) return;
        const fx = (mbr.low[0] - self.lx) / self.vw;
        const fy = (mbr.low[1] - self.ly) / self.vh;
        const s = Star.fromBytes(value);
        const i = star_count * 3;
        stars_buf[i + 0] = @floatCast(fx);
        stars_buf[i + 1] = @floatCast(fy);
        stars_buf[i + 2] = @as(f32, @floatFromInt(s.brightness)) / 255.0;
        star_count += 1;
    }
};

// Refresh stars_buf for the current viewport.
export fn snapshot() void {
    if (!ready) return;
    star_count = 0;
    var c = Collector{
        .lx = game.px - game.view_w / 2,
        .ly = game.py - game.view_h / 2,
        .vw = game.view_w,
        .vh = game.view_h,
    };
    game.queryViewport(&c, Collector.cb) catch {};
}

export fn starsPtr() usize {
    return @intFromPtr(&stars_buf);
}
export fn starsCount() u32 {
    return @intCast(star_count);
}
export fn playerX() f64 {
    return if (ready) game.px else 0;
}
export fn playerY() f64 {
    return if (ready) game.py else 0;
}
export fn viewW() f64 {
    return if (ready) game.view_w else constants.view_w;
}
export fn viewH() f64 {
    return if (ready) game.view_h else constants.view_h;
}

// Zoom: set the viewport to `z` × the base view (z<1 = in, z>1 = out), clamped
// so zooming out never asks reveal() to generate an unbounded number of cells.
const min_zoom = 0.25;
const max_zoom = 4.0;
export fn setZoom(z: f64) u32 {
    if (!ready) return 0;
    const zc = std.math.clamp(z, min_zoom, max_zoom);
    const created = game.setView(constants.view_w * zc, constants.view_h * zc) catch return 0;
    snapshot();
    return @intCast(created);
}

// --- scene stats (what the storage engine is doing under the hood) ---

// Every star ever generated is a live R-tree entry (insert-only), so the id
// counter is the total star count.
export fn totalStars() u32 {
    return if (ready) game.star_counter else 0;
}
// R-tree depth: 0 = a single leaf, higher once it has split into inner levels.
export fn treeHeight() u32 {
    return if (ready) @intCast(game.tree.height() catch 0) else 0;
}
// Pages the device has handed out: the superblock plus every leaf/inode page.
export fn blocksAllocated() u32 {
    return if (ready) @intCast(device.blocksCount()) else 0;
}
export fn pageBytes() u32 {
    return if (ready) @intCast(device.blockSize()) else 0;
}
export fn framesTotal() u32 {
    return @intCast(constants.cache_frames);
}
export fn framesUsed() u32 {
    return if (ready) @intCast(constants.cache_frames - cache.availableFrames()) else 0;
}

// --- the R-tree partition, for a minimap of discovered space ---
// Per node: [x0, y0, x1, y1, level] in world coords (f64 to survive the large
// spawn offsets). The root is emitted first, so box 0 is the whole discovered
// extent; level 0 == leaf.
const max_boxes = 4096;
var boxes_buf: [max_boxes * 5]f64 = undefined;
var box_count: usize = 0;

const BoxCollector = struct {
    fn cb(_: *BoxCollector, mbr: Key, level: usize, is_leaf: bool) anyerror!void {
        _ = is_leaf;
        if (box_count >= max_boxes) return;
        const i = box_count * 5;
        boxes_buf[i + 0] = mbr.low[0];
        boxes_buf[i + 1] = mbr.low[1];
        boxes_buf[i + 2] = mbr.high[0];
        boxes_buf[i + 3] = mbr.high[1];
        boxes_buf[i + 4] = @floatFromInt(level);
        box_count += 1;
    }
};

export fn snapshotBoxes() void {
    box_count = 0;
    if (!ready) return;
    var c = BoxCollector{};
    game.walkNodes(&c, BoxCollector.cb) catch {};
}
export fn boxesPtr() usize {
    return @intFromPtr(&boxes_buf);
}
export fn boxesCount() u32 {
    return @intCast(box_count);
}
