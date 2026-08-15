const std = @import("std");
const fullaz = @import("fullaz");
const cloud = @import("cloud");
const zigline = @import("zigline");
const terminal = @import("demo_common").terminal;

const Io = std.Io;

const constants = cloud.constants;
const Device = fullaz.device.FileBlock(constants.PageId);
const PageCache = fullaz.storage.page_cache.PageCache(Device);
const Cloud = cloud.Cloud(PageCache);

const Options = struct {
    image: []const u8 = "",
    format: bool = false,
    seed: u64 = 42,
    points: u32 = 50_000,
    clusters: u16 = 12,
    // Per cent of the viewport height; see lod.Settings.detail_fraction.
    detail_percent: f64 = constants.default_detail_fraction * 100.0,
    // Camera distance in world cubes. Only applied when formatting; reopening
    // restores whatever the last session was looking at.
    distance_cubes: f64 = constants.default_camera_distance / constants.root_side,
};

const ParseResult = union(enum) {
    run: Options,
    help,
    invalid,
};

const usage =
    "usage: cloud <image> [--format] [--seed N] [--points N] [--clusters N]\n" ++
    "             [--detail PERCENT] [--distance CUBES]\n";

const keys_hint = "h/l yaw  j/k pitch  +/- zoom  [/] detail  i add  d remove 500  w write  q quit";

// Rows reserved for the heads-up display above the viewport.
const hud_rows: usize = 4;
const insert_batch: u32 = 10_000;
const remove_batch: u32 = 500;

// Frame size used when stdout is not a terminal, chosen to fit a README block.
const headless_columns: usize = 78;
const headless_rows: usize = 24;

fn parsePositiveFloat(text: []const u8) ?f64 {
    const value = std.fmt.parseFloat(f64, text) catch return null;
    return if (std.math.isFinite(value) and value > 0) value else null;
}

// Takes the iterator rather than owning one: Options.image borrows from it, so
// it has to outlive the run, not just the parse.
fn parseArgs(args: *std.process.Args.Iterator, err: *Io.Writer) !ParseResult {
    _ = args.skip();

    var options = Options{};
    while (args.next()) |argument| {
        if (std.mem.eql(u8, argument, "--help")) return .help;
        if (std.mem.eql(u8, argument, "--format")) {
            options.format = true;
            continue;
        }
        if (!std.mem.startsWith(u8, argument, "--")) {
            if (options.image.len != 0) {
                try err.print("unexpected argument: {s}\n", .{argument});
                return .invalid;
            }
            options.image = argument;
            continue;
        }

        const value = args.next() orelse {
            try err.print("missing value for {s}\n", .{argument});
            return .invalid;
        };
        if (std.mem.eql(u8, argument, "--seed")) {
            options.seed = std.fmt.parseInt(u64, value, 10) catch {
                try err.writeAll("--seed must be an unsigned integer\n");
                return .invalid;
            };
        } else if (std.mem.eql(u8, argument, "--points")) {
            const parsed = std.fmt.parseInt(u32, value, 10) catch 0;
            if (parsed == 0 or parsed > 2_000_000) {
                try err.writeAll("--points must be in the range 1..2000000\n");
                return .invalid;
            }
            options.points = parsed;
        } else if (std.mem.eql(u8, argument, "--clusters")) {
            const parsed = std.fmt.parseInt(u16, value, 10) catch 0;
            if (parsed == 0 or parsed > cloud.scene.max_clusters) {
                try err.print("--clusters must be in the range 1..{d}\n", .{cloud.scene.max_clusters});
                return .invalid;
            }
            options.clusters = parsed;
        } else if (std.mem.eql(u8, argument, "--detail")) {
            options.detail_percent = parsePositiveFloat(value) orelse {
                try err.writeAll("--detail must be a positive finite number\n");
                return .invalid;
            };
        } else if (std.mem.eql(u8, argument, "--distance")) {
            options.distance_cubes = parsePositiveFloat(value) orelse {
                try err.writeAll("--distance must be a positive finite number\n");
                return .invalid;
            };
        } else {
            try err.print("unknown option: {s}\n", .{argument});
            return .invalid;
        }
    }

    if (options.image.len == 0) {
        try err.writeAll("an image path is required\n");
        return .invalid;
    }
    return .{ .run = options };
}

const Viewport = struct {
    cells: []cloud.ascii.Cell = &.{},
    columns: usize = 0,
    rows: usize = 0,

    fn deinit(self: *Viewport, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
    }

    // Returns true when the terminal changed shape, which invalidates the
    // splat buffer just as surely as moving the camera does.
    fn resize(self: *Viewport, allocator: std.mem.Allocator, size: terminal.Size) !bool {
        const columns = size.columns;
        const rows = if (size.rows > hud_rows) size.rows - hud_rows else 1;
        if (columns == self.columns and rows == self.rows) return false;

        const cells = try allocator.alloc(cloud.ascii.Cell, columns * rows);
        allocator.free(self.cells);
        self.cells = cells;
        self.columns = columns;
        self.rows = rows;
        return true;
    }
};

const Frame = struct {
    grid: cloud.ascii.Grid,
    stats: cloud.lod.Stats,
    dropped: usize,
};

const BrailleAttribute = struct {
    depth: f64 = std.math.inf(f64),
    colour: [3]u8 = .{ 0, 0, 0 },
};

// Braille gives the interactive viewer a 2x4 dot grid per terminal cell. The
// scene stays here rather than in cloud's wasm-safe library surface because it
// owns terminal-specific zigline storage.
const BrailleViewport = struct {
    scene: ?zigline.braille.DynamicScene = null,
    attributes: []BrailleAttribute = &.{},
    columns: usize = 0,
    rows: usize = 0,

    fn deinit(self: *BrailleViewport, allocator: std.mem.Allocator) void {
        if (self.scene) |*scene| {
            scene.deinit();
        }
        allocator.free(self.attributes);
    }

    fn resize(self: *BrailleViewport, allocator: std.mem.Allocator, size: terminal.Size) !bool {
        const columns = size.columns;
        const rows = if (size.rows > hud_rows) size.rows - hud_rows else 1;
        if (columns == self.columns and rows == self.rows) {
            return false;
        }

        const dot_width = try std.math.mul(usize, columns, 2);
        const dot_height = try std.math.mul(usize, rows, 4);
        var replacement = try zigline.braille.DynamicScene.init(
            allocator,
            dot_width,
            dot_height,
        );
        errdefer replacement.deinit();
        const attributes = try allocator.alloc(BrailleAttribute, try std.math.mul(usize, columns, rows));
        if (self.scene) |*scene| {
            scene.deinit();
        }
        allocator.free(self.attributes);
        self.scene = replacement;
        self.attributes = attributes;
        self.columns = columns;
        self.rows = rows;
        return true;
    }

    fn beginFrame(self: *BrailleViewport) *zigline.braille.DynamicScene {
        const scene = &self.scene.?;
        scene.clean();
        for (self.attributes) |*attribute| {
            attribute.* = .{};
        }
        return scene;
    }
};

const BrailleSink = struct {
    scene: *zigline.braille.DynamicScene,
    attributes: []BrailleAttribute,

    pub fn push(self: *BrailleSink, splat: cloud.lod.Splat) void {
        const width: f64 = @floatFromInt(self.scene.dot_width);
        const height: f64 = @floatFromInt(self.scene.dot_height);
        if (!(splat.x >= 0) or !(splat.x < width) or
            !(splat.y >= 0) or !(splat.y < height) or
            !(splat.depth > 0))
        {
            return;
        }

        const x: usize = @intFromFloat(splat.x);
        const y: usize = @intFromFloat(splat.y);
        _ = self.scene.setDot(x, y);

        const attribute = &self.attributes[(y / 4) * self.scene.width_in_cells + x / 2];
        if (splat.depth < attribute.depth) {
            attribute.* = .{
                .depth = splat.depth,
                .colour = .{ splat.r, splat.g, splat.b },
            };
        }
    }
};

const BrailleRenderer = struct {
    attributes: []const BrailleAttribute,
    width: usize,

    pub const Error = std.Io.Writer.Error;

    pub fn beginRender(_: *BrailleRenderer, _: *Io.Writer) Error!void {}

    pub fn beforeCell(
        self: *BrailleRenderer,
        out: *Io.Writer,
        column: usize,
        row: usize,
        glyph: []const u8,
    ) Error!void {
        if (std.mem.eql(u8, glyph, "\xE2\xA0\x80")) {
            try out.writeAll("\x1b[39m");
            return;
        }
        const colour = self.attributes[row * self.width + column].colour;
        try out.print("\x1b[38;2;{d};{d};{d}m", .{ colour[0], colour[1], colour[2] });
    }

    pub fn endRender(_: *BrailleRenderer, out: *Io.Writer) Error!void {
        try out.writeAll("\x1b[39m");
    }
};

fn renderFrame(viewport: *Viewport, c: *Cloud, detail: f64) !Frame {
    var grid = try cloud.ascii.Grid.init(viewport.cells, viewport.columns, viewport.rows);
    grid.clear();

    const projector = cloud.camera.Projector.init(&c.camera, .{
        .width = @intCast(viewport.columns),
        .height = @intCast(viewport.rows),
        // A terminal cell is about twice as tall as it is wide.
        .cell_aspect = 2.0,
    });

    var sink = cloud.ascii.GridSink{ .grid = &grid };
    const stats = try cloud.lod.collect(&c.tree, &projector, .{ .detail_fraction = detail }, &sink);
    return .{ .grid = grid, .stats = stats, .dropped = sink.dropped };
}

fn renderBrailleFrame(viewport: *BrailleViewport, c: *Cloud, detail: f64) !cloud.lod.Stats {
    const scene = viewport.beginFrame();

    const projector = cloud.camera.Projector.init(&c.camera, .{
        .width = @intCast(scene.dot_width),
        .height = @intCast(scene.dot_height),
        // A 2x4 Braille cell maps to roughly square dots on a 2:1 terminal.
        .cell_aspect = 1.0,
    });
    var sink = BrailleSink{ .scene = scene, .attributes = viewport.attributes };
    return cloud.lod.collect(&c.tree, &projector, .{ .detail_fraction = detail }, &sink);
}

fn writeHud(
    out: *Io.Writer,
    c: *Cloud,
    stats: cloud.lod.Stats,
    detail_fraction: f64,
    status: []const u8,
) !void {
    const points = try c.pointCount();
    const bytes = c.imageBytes();
    const per_point = if (points == 0) 0 else bytes / points;
    const free_pages = c.freePageCount();
    const reused_pages = c.reusedPageCount();

    try out.print("fullaz . cloud | points {d} | splats {d} | aggregates {d} | drawn {d}\x1b[K\r\n", .{
        points,
        stats.splats_emitted,
        stats.nodes_accepted,
        stats.points_visited,
    });
    try out.print("nodes visited {d} | empty {d} | culled {d} | detail {d:.2}% | dist {d:.0}\x1b[K\r\n", .{
        stats.nodes_visited,
        stats.nodes_empty,
        stats.nodes_culled,
        detail_fraction * 100.0,
        c.camera.distance,
    });
    try out.print("image {d} KiB in {d} pages ({d} B/point) | free {d} | reused {d} | seed {d}{s}{s}\x1b[K\r\n", .{
        bytes / 1024,
        bytes / constants.block_size,
        per_point,
        free_pages,
        reused_pages,
        c.spec.seed,
        if (status.len == 0) "" else " | ",
        status,
    });
    try out.print("{s}\x1b[K\r\n", .{keys_hint});
}

fn run(init: std.process.Init, out: *Io.Writer, options: Options) !void {
    const allocator = init.gpa;
    const io = init.io;

    var device = if (options.format)
        try Device.create(io, options.image, constants.block_size)
    else
        try Device.open(io, options.image, constants.block_size);
    defer device.deinit();

    var cache = try PageCache.init(&device, allocator, constants.cache_frames);
    defer cache.deinit();

    var c = if (options.format)
        try Cloud.format(allocator, &cache, constants.block_size, .{
            .seed = options.seed,
            .cluster_count = options.clusters,
        }, options.points)
    else
        try Cloud.open(allocator, &cache, constants.block_size);
    defer c.deinit();

    if (options.format) {
        c.detail_fraction = options.detail_percent / 100.0;
        c.camera.distance = options.distance_cubes * constants.root_side;
    }

    // Without a terminal there is nothing to drive, but building an image from
    // a script is still worth doing, so report and exit rather than refuse.
    if (!try Io.File.stdin().isTty(io) or !try Io.File.stdout().isTty(io)) {
        try c.save();
        try device.sync();

        var viewport = Viewport{};
        defer viewport.deinit(allocator);
        _ = try viewport.resize(allocator, .{
            .columns = headless_columns,
            .rows = headless_rows + hud_rows,
        });

        var frame = try renderFrame(&viewport, &c, c.detail_fraction);
        // Plain text, plain newlines: the frame is being piped somewhere.
        try cloud.ascii.writeFrame(&frame.grid, out, .{
            .colour = false,
            .erase_line = false,
            .newline = "\n",
        });

        const points = try c.pointCount();
        const bytes = c.imageBytes();
        try out.print("\n{s}: {d} points, {d} KiB in {d} pages ({d} B/point), {d} free, {d} reused, seed {d}\n", .{
            options.image,
            points,
            bytes / 1024,
            bytes / constants.block_size,
            if (points == 0) 0 else bytes / points,
            c.freePageCount(),
            c.reusedPageCount(),
            c.spec.seed,
        });
        try out.print("{d} splats: {d} aggregates + {d} points, {d} nodes seen\n", .{
            frame.stats.splats_emitted,
            frame.stats.nodes_accepted,
            frame.stats.points_visited,
            frame.stats.nodes_visited,
        });
        try out.flush();
        return;
    }

    var raw = zigline.terminal.RawMode.enable() catch {
        try out.writeAll("cloud: failed to enable terminal raw mode\n");
        try out.flush();
        return;
    };
    defer raw.disable();
    defer terminal.restore(out);
    try terminal.clear(out);
    try out.writeAll("\x1b[?25l");

    var viewport = BrailleViewport{};
    defer viewport.deinit(allocator);

    var stats = cloud.lod.Stats{};
    var status: []const u8 = "";
    var quit = false;
    // The splat buffer only changes when the camera, the threshold, the point
    // set or the terminal does. Four sources, all of them set this.
    var dirty = true;

    while (!quit) {
        if (try viewport.resize(allocator, terminal.dimensions(io))) dirty = true;

        if (dirty) {
            stats = try renderBrailleFrame(&viewport, &c, c.detail_fraction);
            dirty = false;

            try terminal.home(out);
            try writeHud(out, &c, stats, c.detail_fraction, status);
            try out.flush();
            const scene = &viewport.scene.?;
            var renderer = BrailleRenderer{
                .attributes = viewport.attributes,
                .width = scene.width_in_cells,
            };
            try scene.renderWithAt(out, 0, hud_rows, &renderer, BrailleRenderer);
            try out.flush();
            status = "";
        }

        while (terminal.pollByte()) |key| {
            switch (key) {
                'q', 'Q' => quit = true,
                'h' => {
                    c.camera.orbit(-0.08, 0);
                    dirty = true;
                },
                'l' => {
                    c.camera.orbit(0.08, 0);
                    dirty = true;
                },
                'j' => {
                    c.camera.orbit(0, -0.06);
                    dirty = true;
                },
                'k' => {
                    c.camera.orbit(0, 0.06);
                    dirty = true;
                },
                '+', '=' => {
                    c.camera.dolly(1.0 / 1.25);
                    dirty = true;
                },
                '-', '_' => {
                    c.camera.dolly(1.25);
                    dirty = true;
                },
                '[' => {
                    c.detail_fraction = @max(c.detail_fraction / 1.5, 0.002);
                    dirty = true;
                },
                ']' => {
                    c.detail_fraction = @min(c.detail_fraction * 1.5, 2.0);
                    dirty = true;
                },
                'i', 'I' => {
                    _ = try c.insertPoints(insert_batch);
                    status = "points added";
                    dirty = true;
                },
                'd', 'D' => {
                    const removed = try c.removePoints(remove_batch);
                    status = if (removed == 0) "no points to remove" else "points removed";
                    dirty = true;
                },
                'w', 'W' => {
                    try c.save();
                    try device.sync();
                    status = "saved";
                    dirty = true;
                },
                else => {},
            }
        }

        try io.sleep(.fromNanoseconds(16 * std.time.ns_per_ms), .awake);
    }

    try c.save();
    try device.sync();
}

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [256 * 1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const err = &stderr_writer.interface;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();

    switch (try parseArgs(&args, err)) {
        .help => {
            try out.writeAll(usage);
            try out.flush();
        },
        .invalid => {
            try err.writeAll(usage);
            try err.flush();
        },
        .run => |options| try run(init, out, options),
    }
}
