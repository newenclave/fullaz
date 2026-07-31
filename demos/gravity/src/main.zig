const std = @import("std");
const gravity = @import("gravity");
const zigline = @import("zigline");
const terminal = @import("terminal.zig");

const Io = std.Io;

const Options = struct {
    body_count: usize = 300,
    theta: f64 = 0.5,
    time_step: f64 = 0.002,
    seed: u64 = 42,
    central_mass: f64 = 100_000_000.0,
};

const ParseResult = union(enum) {
    run: Options,
    help,
    invalid,
};

const usage = "usage: gravity [--bodies N] [--theta X] [--dt X] [--seed N] [--central-mass X]\n";

fn parsePositiveFloat(text: []const u8) ?f64 {
    const value = std.fmt.parseFloat(f64, text) catch return null;
    return if (std.math.isFinite(value) and value > 0) value else null;
}

fn parseArgs(init: std.process.Init, allocator: std.mem.Allocator, err: *Io.Writer) !ParseResult {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.skip();

    var options = Options{};
    while (args.next()) |option| {
        if (std.mem.eql(u8, option, "--help")) return .help;
        const value = args.next() orelse {
            try err.print("missing value for {s}\n", .{option});
            return .invalid;
        };
        if (std.mem.eql(u8, option, "--bodies")) {
            const parsed = std.fmt.parseInt(usize, value, 10) catch 0;
            if (parsed == 0 or parsed > 1_000_000) {
                try err.writeAll("--bodies must be in the range 1..1000000\n");
                return .invalid;
            }
            options.body_count = parsed;
        } else if (std.mem.eql(u8, option, "--theta")) {
            options.theta = parsePositiveFloat(value) orelse {
                try err.writeAll("--theta must be a positive finite number\n");
                return .invalid;
            };
        } else if (std.mem.eql(u8, option, "--dt")) {
            options.time_step = parsePositiveFloat(value) orelse {
                try err.writeAll("--dt must be a positive finite number\n");
                return .invalid;
            };
        } else if (std.mem.eql(u8, option, "--seed")) {
            options.seed = std.fmt.parseInt(u64, value, 10) catch {
                try err.writeAll("--seed must be an unsigned integer\n");
                return .invalid;
            };
        } else if (std.mem.eql(u8, option, "--central-mass")) {
            options.central_mass = parsePositiveFloat(value) orelse {
                try err.writeAll("--central-mass must be a positive finite number\n");
                return .invalid;
            };
        } else {
            try err.print("unknown option: {s}\n", .{option});
            return .invalid;
        }
    }
    return .{ .run = options };
}

fn cameraBounds(bodies: []const gravity.Body) gravity.Box {
    var low = bodies[0].position;
    var high = bodies[0].position;
    for (bodies[1..]) |body| {
        low[0] = @min(low[0], body.position[0]);
        low[1] = @min(low[1], body.position[1]);
        high[0] = @max(high[0], body.position[0]);
        high[1] = @max(high[1], body.position[1]);
    }
    inline for (0..2) |axis| {
        const span = @max(high[axis] - low[axis], 20.0);
        const padding = span * 0.1;
        low[axis] -= padding;
        high[axis] += padding;
    }
    return gravity.Box.create(low, high);
}

fn glyph(density: usize, central: bool) []const u8 {
    if (central) return "★";
    return switch (density) {
        0 => " ",
        1 => "·",
        2 => "∙",
        3...4 => "•",
        5...8 => "●",
        else => "◆",
    };
}

fn render(
    allocator: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    bodies: []const gravity.Body,
    simulation: *gravity.Simulation,
    config: gravity.Config,
    step: usize,
    running: bool,
    jump_input: []const u8,
    status: []const u8,
) !void {
    const size = terminal.dimensions(io);
    try terminal.home(out);
    if (size.columns < 30 or size.rows < 10) {
        try out.writeAll("Terminal is too small. Resize to at least 30x10.\x1b[J");
        try out.flush();
        return;
    }

    const width = size.columns;
    const height = size.rows - 4;
    const cells = try std.math.mul(usize, width, height);
    const density = try allocator.alloc(usize, cells);
    defer allocator.free(density);
    @memset(density, 0);
    const central = try allocator.alloc(bool, cells);
    defer allocator.free(central);
    @memset(central, false);

    const camera = cameraBounds(bodies);
    const span_x = camera.high[0] - camera.low[0];
    const span_y = camera.high[1] - camera.low[1];
    for (bodies) |body| {
        const projected_x = (body.position[0] - camera.low[0]) / span_x * @as(f64, @floatFromInt(width - 1));
        const projected_y = (body.position[1] - camera.low[1]) / span_y * @as(f64, @floatFromInt(height - 1));
        const x: usize = @intFromFloat(std.math.clamp(projected_x, 0, @as(f64, @floatFromInt(width - 1))));
        const y: usize = @intFromFloat(std.math.clamp(projected_y, 0, @as(f64, @floatFromInt(height - 1))));
        const index = (height - y - 1) * width + x;
        if (body.id == 0) central[index] = true else density[index] += 1;
    }

    const bounds = simulation.tree.bounds().?;
    try out.print("Barnes-Hut galaxy | {s} | step {d} | bodies {d} | nodes {d}\x1b[K\n", .{
        if (running) "RUNNING" else "PAUSED",
        step,
        bodies.len,
        try simulation.nodeCount(),
    });
    try out.print("theta={d:.3} dt={d:.4} root=[{d:.1},{d:.1}]-[{d:.1},{d:.1}]\x1b[K\n", .{
        config.theta,
        config.time_step,
        bounds.low[0],
        bounds.low[1],
        bounds.high[0],
        bounds.high[1],
    });
    try out.writeAll("Space run/pause | n step | g jump | q quit");
    if (jump_input.len > 0) try out.print(" | jump steps: {s}", .{jump_input});
    if (status.len > 0) try out.print(" | {s}", .{status});
    try out.writeAll("\x1b[K\n");

    for (0..height) |row| {
        for (0..width) |column| {
            const index = row * width + column;
            if (central[index]) {
                try out.writeAll("\x1b[95m");
            } else if (density[index] >= 5) {
                try out.writeAll("\x1b[93m");
            } else if (density[index] != 0) {
                try out.writeAll("\x1b[96m");
            }
            try out.writeAll(glyph(density[index], central[index]));
            if (central[index] or density[index] != 0) try out.writeAll("\x1b[0m");
        }
        if (row + 1 < height) try out.writeByte('\n');
    }
    try out.flush();
}

fn run(init: std.process.Init, out: *Io.Writer, options: Options) !void {
    const allocator = init.gpa;
    const io = init.io;
    if (!try Io.File.stdin().isTty(io) or !try Io.File.stdout().isTty(io)) {
        try out.writeAll("gravity: interactive demo requires a terminal\n");
        try out.flush();
        return;
    }

    var bodies = try gravity.makeGalaxy(allocator, .{
        .body_count = options.body_count,
        .seed = options.seed,
        .central_mass = options.central_mass,
    });
    defer bodies.deinit(allocator);
    var simulation = try gravity.Simulation.init(allocator, bodies.items);
    defer simulation.deinit();
    const config = gravity.Config{ .theta = options.theta, .time_step = options.time_step };

    var raw = zigline.terminal.RawMode.enable() catch {
        try out.writeAll("gravity: failed to enable terminal raw mode\n");
        try out.flush();
        return;
    };
    defer raw.disable();
    defer terminal.restore(out);
    try terminal.clear(out);
    try out.writeAll("\x1b[?25l");

    var running = false;
    var quit = false;
    var reading_jump = false;
    var jump_buffer: [20]u8 = undefined;
    var jump_length: usize = 0;
    var status: []const u8 = "";
    var step: usize = 0;

    while (!quit) {
        try render(allocator, io, out, bodies.items, &simulation, config, step, running, jump_buffer[0..jump_length], status);
        status = "";
        while (terminal.pollByte()) |key| {
            if (reading_jump) {
                if (key >= '0' and key <= '9' and jump_length < jump_buffer.len) {
                    jump_buffer[jump_length] = key;
                    jump_length += 1;
                } else if (key == '\x08' or key == '\x7f') {
                    if (jump_length > 0) jump_length -= 1;
                } else if (key == '\r' or key == '\n') {
                    const jump_steps = std.fmt.parseInt(usize, jump_buffer[0..jump_length], 10) catch 0;
                    if (jump_steps == 0 or jump_steps > 1_000_000) {
                        status = "enter 1..1000000 steps";
                    } else {
                        for (0..jump_steps) |_| try simulation.advance(bodies.items, config);
                        step += jump_steps;
                    }
                    jump_length = 0;
                    reading_jump = false;
                } else if (key == '\x1b') {
                    jump_length = 0;
                    reading_jump = false;
                }
                continue;
            }

            switch (key) {
                'q', 'Q' => quit = true,
                ' ' => running = !running,
                'n', 'N' => if (!running) {
                    try simulation.advance(bodies.items, config);
                    step += 1;
                },
                'g', 'G' => {
                    if (!running) reading_jump = true;
                },
                else => {},
            }
        }
        if (running) {
            try simulation.advance(bodies.items, config);
            step += 1;
        }
        try io.sleep(.fromNanoseconds(16 * std.time.ns_per_ms), .awake);
    }
}

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const err = &stderr_writer.interface;

    switch (try parseArgs(init, init.gpa, err)) {
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
