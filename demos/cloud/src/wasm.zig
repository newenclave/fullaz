const std = @import("std");
const fullaz = @import("fullaz");
const cloud = @import("cloud");

const constants = cloud.constants;

// Freestanding wasm has no default panic handler (the std one needs the OS).
// Trap on panic -- the JS side sees the instance abort.
pub const panic = std.debug.FullPanic(struct {
    fn f(_: []const u8, _: ?usize) noreturn {
        @trap();
    }
}.f);

const allocator = std.heap.wasm_allocator;

const Device = fullaz.device.MemoryBlock(constants.PageId);
const PageCache = fullaz.storage.page_cache.PageCache(Device);
const Cloud = cloud.Cloud(PageCache);

var device: Device = undefined;
var cache: PageCache = undefined;
var world: Cloud = undefined;
var ready = false;
var last_error: []const u8 = "";

// Static so the pointer handed to JS never moves; only detachment on heap
// growth has to be worried about, which is why JS re-views every frame.
const max_splats = 131_072;
var splats: [max_splats * 8]f32 = undefined;
var splat_count: usize = 0;
var dropped_splats: usize = 0;
var last_stats: cloud.lod.Stats = .{};

const max_mapped_pages = 65_536;
var page_roles: [max_mapped_pages]u8 = undefined;
var mapped_pages: usize = 0;

pub const role_unknown: u8 = 0;
pub const role_superblock: u8 = 1;
pub const role_nodes: u8 = 2;
pub const role_entries: u8 = 3;
pub const role_fsm: u8 = 4;

fn fail(err: anyerror) u32 {
    last_error = @errorName(err);
    return 0;
}

fn teardown() void {
    if (!ready) return;
    world.deinit();
    cache.deinit();
    device.deinit();
    ready = false;
}

const BufferSink = struct {
    written: usize = 0,
    dropped: usize = 0,

    pub fn push(self: *BufferSink, splat: cloud.lod.Splat) void {
        if (self.written >= max_splats) {
            self.dropped += 1;
            return;
        }
        const base = self.written * 8;
        splats[base + 0] = @floatCast(splat.x);
        splats[base + 1] = @floatCast(splat.y);
        splats[base + 2] = @floatCast(splat.radius);
        splats[base + 3] = @floatCast(splat.depth);
        splats[base + 4] = @floatFromInt(splat.r);
        splats[base + 5] = @floatFromInt(splat.g);
        splats[base + 6] = @floatFromInt(splat.b);
        splats[base + 7] = @floatFromInt(splat.count);
        self.written += 1;
    }
};

export fn format(seed: u32, points: u32, clusters: u32) u32 {
    teardown();

    device = Device.init(allocator, constants.block_size) catch |err| return fail(err);
    cache = PageCache.init(&device, allocator, constants.cache_frames) catch |err| {
        device.deinit();
        return fail(err);
    };
    world = Cloud.format(allocator, &cache, constants.block_size, .{
        .seed = seed,
        .cluster_count = @intCast(@min(@max(clusters, 1), cloud.scene.max_clusters)),
    }, @min(points, 2_000_000)) catch |err| {
        cache.deinit();
        device.deinit();
        return fail(err);
    };

    ready = true;
    last_error = "";
    return 1;
}

export fn importImage(ptr: usize, len: usize) u32 {
    if (len == 0 or len % constants.block_size != 0) {
        last_error = "InvalidImageSize";
        return 0;
    }
    teardown();

    device = Device.init(allocator, constants.block_size) catch |err| return fail(err);
    device.storage.resize(allocator, len) catch |err| {
        device.deinit();
        return fail(err);
    };
    const bytes: [*]const u8 = @ptrFromInt(ptr);
    @memcpy(device.storage.items, bytes[0..len]);

    cache = PageCache.init(&device, allocator, constants.cache_frames) catch |err| {
        device.deinit();
        return fail(err);
    };
    world = Cloud.open(allocator, &cache, constants.block_size) catch |err| {
        cache.deinit();
        device.deinit();
        return fail(err);
    };

    ready = true;
    last_error = "";
    return 1;
}

// Flushes first: without it the raw device bytes are not a valid image.
export fn imagePtr() usize {
    if (!ready) return 0;
    world.save() catch |err| {
        _ = fail(err);
        return 0;
    };
    return @intFromPtr(device.storage.items.ptr);
}

export fn imageLen() usize {
    return if (ready) device.storage.items.len else 0;
}

export fn allocate(len: usize) usize {
    const bytes = allocator.alloc(u8, len) catch return 0;
    return @intFromPtr(bytes.ptr);
}

export fn freeAllocation(ptr: usize, len: usize) void {
    if (len == 0) return;
    const bytes: [*]u8 = @ptrFromInt(ptr);
    allocator.free(bytes[0..len]);
}

export fn orbit(dyaw: f64, dpitch: f64) void {
    if (!ready) return;
    world.camera.orbit(dyaw, dpitch);
}

export fn dolly(factor: f64) void {
    if (!ready) return;
    world.camera.dolly(factor);
}

// A fraction of the viewport height, so the same number means the same thing
// in a canvas and in a character grid.
export fn setDetail(fraction: f64) void {
    if (!ready) return;
    if (!std.math.isFinite(fraction) or !(fraction >= 0)) return;
    world.detail_fraction = @min(fraction, 2.0);
}

export fn detailFraction() f64 {
    return if (ready) world.detail_fraction else 0;
}

export fn cameraDistance() f64 {
    return if (ready) world.camera.distance else 0;
}

export fn insertPoints(count: u32) u32 {
    if (!ready) return 0;
    return world.insertPoints(@min(count, 500_000)) catch |err| fail(err);
}

export fn renderFrame(width: u32, height: u32) u32 {
    if (!ready) return 0;

    const projector = cloud.camera.Projector.init(&world.camera, .{
        .width = @max(width, 1),
        .height = @max(height, 1),
    });
    var sink = BufferSink{};
    last_stats = cloud.lod.collect(
        &world.tree,
        &projector,
        .{ .detail_fraction = world.detail_fraction },
        &sink,
    ) catch |err| return fail(err);

    splat_count = sink.written;
    dropped_splats = sink.dropped;
    last_error = "";
    return @intCast(splat_count);
}

export fn splatsPtr() usize {
    return @intFromPtr(&splats);
}

export fn splatsCount() u32 {
    return @intCast(splat_count);
}

export fn splatsDropped() u32 {
    return @intCast(dropped_splats);
}

// The page header starts with its kind, so the role of a page is the first two
// bytes -- except page zero, which is a raw superblock with no fullaz header.
fn roleOf(pid: usize, bytes: []const u8) u8 {
    if (pid == constants.superblock_pid) return role_superblock;
    if (bytes.len < 2) return role_unknown;
    const kind = std.mem.readInt(u16, bytes[0..2], constants.endian);
    return switch (kind) {
        constants.tree_settings.node_page_kind => role_nodes,
        constants.tree_settings.entry_page_kind => role_entries,
        Cloud.fsm_page_kind => role_fsm,
        else => role_unknown,
    };
}

export fn snapshotPages() u32 {
    if (!ready) return 0;
    cache.flushAll() catch |err| return fail(err);

    const block_size = constants.block_size;
    const total = @min(device.blocksCount(), max_mapped_pages);
    var pid: usize = 0;
    while (pid < total) : (pid += 1) {
        const start = pid * block_size;
        page_roles[pid] = roleOf(pid, device.storage.items[start..][0..block_size]);
    }
    mapped_pages = total;
    last_error = "";
    return @intCast(total);
}

export fn pageRolesPtr() usize {
    return @intFromPtr(&page_roles);
}

export fn pageRolesCount() u32 {
    return @intCast(mapped_pages);
}

export fn pointCount() u32 {
    if (!ready) return 0;
    return @intCast(world.pointCount() catch 0);
}

export fn pagesTotal() u32 {
    return if (ready) @intCast(device.blocksCount()) else 0;
}

export fn pageBytes() u32 {
    return constants.block_size;
}

export fn nodesVisited() u32 {
    return @intCast(last_stats.nodes_visited);
}

export fn nodesAccepted() u32 {
    return @intCast(last_stats.nodes_accepted);
}

export fn nodesCulled() u32 {
    return @intCast(last_stats.nodes_culled);
}

export fn pointsDrawn() u32 {
    return @intCast(last_stats.points_visited);
}

export fn worldSide() f32 {
    return constants.root_side;
}

export fn lastErrorPtr() usize {
    return @intFromPtr(last_error.ptr);
}

export fn lastErrorLen() usize {
    return last_error.len;
}
