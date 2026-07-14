const std = @import("std");
const fullaz = @import("fullaz");
const galaxy = @import("galaxy");

const constants = galaxy.constants;
const Star = galaxy.starfield.Star;

const Device = fullaz.device.MemoryBlock(u32);
const PageCache = fullaz.storage.page_cache.PageCache(Device);

// One Galaxy type per insertion strategy. All three share the same page layout
// and Key, so JS can rebuild the world under any of them on the same seed.
const GGuttman = galaxy.Galaxy(PageCache, .guttman);
const GLinear = galaxy.Galaxy(PageCache, .linear);
const GHybrid = galaxy.Galaxy(PageCache, .hybrid);
const Key = GHybrid.KeyType;

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

// The active world. Every variant is a Galaxy differing only in its comptime
// strategy, so field/method names line up and `inline else` dispatches to all
// three with a single arm.
const GameUnion = union(enum) {
    guttman: GGuttman,
    linear: GLinear,
    hybrid: GHybrid,
};

var device: Device = undefined;
var cache: PageCache = undefined;
var game: GameUnion = undefined;
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
    if (!ready) {
        return;
    }
    switch (game) {
        inline else => |*g| g.deinit(),
    }
    cache.deinit();
    device.deinit();
    ready = false;
}

// strat: 0 = Guttman, 1 = Linear, 2 = Hybrid (R* choose+split, no reinsert).
export fn init(seed: u32, strat: u32) void {
    teardown();
    device = Device.init(gpa, constants.default_block_size) catch @trap();
    cache = PageCache.init(&device, gpa, constants.cache_frames) catch @trap();
    const spawn = deriveSpawn(seed);
    const bs: u32 = @intCast(constants.default_block_size);
    game = switch (strat) {
        1 => .{ .linear = GLinear.format(gpa, &cache, bs, seed, spawn[0], spawn[1]) catch @trap() },
        2 => .{ .hybrid = GHybrid.format(gpa, &cache, bs, seed, spawn[0], spawn[1]) catch @trap() },
        else => .{ .guttman = GGuttman.format(gpa, &cache, bs, seed, spawn[0], spawn[1]) catch @trap() },
    };
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
    const created = switch (game) {
        inline else => |*g| g.move(d) catch return 0,
    };
    snapshot();
    return @intCast(created);
}

// Free pan by a world-space delta (from mouse/touch drag on the JS side).
export fn panBy(dx: f64, dy: f64) u32 {
    if (!ready) {
        return 0;
    }
    const created = switch (game) {
        inline else => |*g| g.moveBy(dx, dy) catch return 0,
    };
    snapshot();
    return @intCast(created);
}

const Collector = struct {
    lx: f64,
    ly: f64,
    vw: f64,
    vh: f64,

    fn cb(self: *Collector, mbr: Key, value: []const u8) anyerror!void {
        if (star_count >= max_stars) {
            return;
        }
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
    if (!ready) {
        return;
    }
    star_count = 0;
    switch (game) {
        inline else => |*g| {
            var c = Collector{
                .lx = g.px - g.view_w / 2,
                .ly = g.py - g.view_h / 2,
                .vw = g.view_w,
                .vh = g.view_h,
            };
            g.queryViewport(&c, Collector.cb) catch {};
        },
    }
}

export fn starsPtr() usize {
    return @intFromPtr(&stars_buf);
}
export fn starsCount() u32 {
    return @intCast(star_count);
}
export fn playerX() f64 {
    if (!ready) return 0;
    return switch (game) {
        inline else => |*g| g.px,
    };
}
export fn playerY() f64 {
    if (!ready) return 0;
    return switch (game) {
        inline else => |*g| g.py,
    };
}
export fn viewW() f64 {
    if (!ready) return constants.view_w;
    return switch (game) {
        inline else => |*g| g.view_w,
    };
}
export fn viewH() f64 {
    if (!ready) return constants.view_h;
    return switch (game) {
        inline else => |*g| g.view_h,
    };
}

const min_zoom = 0.25;
const max_zoom = 4.0;
export fn setZoom(z: f64) u32 {
    if (!ready) {
        return 0;
    }
    const zc = std.math.clamp(z, min_zoom, max_zoom);
    const created = switch (game) {
        inline else => |*g| g.setView(constants.view_w * zc, constants.view_h * zc) catch return 0,
    };
    snapshot();
    return @intCast(created);
}

// --- scene stats (what the storage engine is doing under the hood) ---

// Every star ever generated is a live R-tree entry (insert-only), so the id
// counter is the total star count.
export fn totalStars() u32 {
    if (!ready) return 0;
    return switch (game) {
        inline else => |*g| g.star_counter,
    };
}
// R-tree depth: 0 = a single leaf, higher once it has split into inner levels.
export fn treeHeight() u32 {
    if (!ready) return 0;
    const height = switch (game) {
        inline else => |*g| g.tree.height() catch 0,
    };
    return @intCast(height);
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
    if (!ready) {
        return;
    }
    var c = BoxCollector{};
    switch (game) {
        inline else => |*g| g.walkNodes(&c, BoxCollector.cb) catch {},
    }
}
export fn boxesPtr() usize {
    return @intFromPtr(&boxes_buf);
}
export fn boxesCount() u32 {
    return @intCast(box_count);
}
