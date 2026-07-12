const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const fullaz = @import("fullaz");
const zigline = @import("zigline");
const galaxy = @import("galaxy");
const device = fullaz.device;

// The starmap is UTF-8 (·, ✦, …).
extern "kernel32" fn SetConsoleOutputCP(wCodePageID: c_uint) callconv(.winapi) c_int;

fn enableUtf8Console() void {
    if (builtin.os.tag == .windows) {
        _ = SetConsoleOutputCP(65001);
    }
}

const constants = galaxy.constants;

const Device = device.FileBlock(constants.PageId);
const PageCache = fullaz.storage.page_cache.PageCache(Device);
const G = galaxy.Galaxy(PageCache, true);

const help_text =
    \\commands:
    \\  look, l            render the starmap around you
    \\  w / a / s / d      fly north / west / south / east (also: north south east west)
    \\  where              print your position
    \\  save               write the galaxy to its file
    \\  help               this text
    \\  quit, exit         save and leave
    \\
;

fn dirOf(cmd: []const u8) ?galaxy.Direction {
    const eq = std.mem.eql;
    if (eq(u8, cmd, "w") or eq(u8, cmd, "n") or eq(u8, cmd, "north")) {
        return .north;
    }
    if (eq(u8, cmd, "s") or eq(u8, cmd, "south")) {
        return .south;
    }
    if (eq(u8, cmd, "d") or eq(u8, cmd, "e") or eq(u8, cmd, "east")) {
        return .east;
    }
    if (eq(u8, cmd, "a") or eq(u8, cmd, "west")) {
        return .west;
    }
    return null;
}

const Shell = struct {
    g: *G,
    cache: *PageCache,
    dev: *Device,
    out: *Io.Writer,

    fn persist(self: *Shell) !void {
        try self.g.save();
        try self.cache.flushAll();
        try self.dev.sync();
    }

    // Returns false when the session should end.
    fn exec(self: *Shell, line: []const u8) !bool {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
        const cmd = it.next() orelse return true;

        if (std.mem.eql(u8, cmd, "quit") or std.mem.eql(u8, cmd, "exit")) {
            return false;
        } else if (std.mem.eql(u8, cmd, "help")) {
            try self.out.writeAll(help_text);
        } else if (std.mem.eql(u8, cmd, "look") or std.mem.eql(u8, cmd, "l")) {
            try self.g.render(self.out);
        } else if (std.mem.eql(u8, cmd, "where")) {
            try self.out.print("at ({d:.1}, {d:.1})  view {d:.0}x{d:.0}\n", .{ self.g.px, self.g.py, self.g.view_w, self.g.view_h });
        } else if (std.mem.eql(u8, cmd, "save")) {
            try self.persist();
            try self.out.writeAll("saved\n");
        } else if (dirOf(cmd)) |dir| {
            const created = try self.g.move(dir);
            if (created > 0) {
                try self.out.print("{d} new star(s) drift into view\n", .{created});
            }
            try self.g.render(self.out);
        } else {
            try self.out.print("unknown command '{s}' (try 'help')\n", .{cmd});
        }
        return true;
    }
};

fn deriveSpawn(seed: u64) [2]f64 {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x9e3779b97f4a7c15);
    const r = prng.random();
    return .{ r.float(f64) * 1.0e6, r.float(f64) * 1.0e6 };
}

pub fn main(init: std.process.Init) !void {
    enableUtf8Console();

    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_fw.interface;

    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();
    _ = args_it.skip();

    const image = args_it.next() orelse {
        try out.writeAll("usage: galaxy <image> [--format] [--seed N] [command]\n");
        try out.flush();
        return;
    };

    var do_format = false;
    var seed: ?u64 = null;
    var cmd_buf: [64][]const u8 = undefined;
    var cmd_n: usize = 0;
    while (args_it.next()) |t| {
        if (std.mem.eql(u8, t, "--format")) {
            do_format = true;
        } else if (std.mem.eql(u8, t, "--seed")) {
            const v = args_it.next() orelse {
                try out.writeAll("--seed needs a value\n");
                try out.flush();
                return;
            };
            seed = std.fmt.parseInt(u64, v, 10) catch {
                try out.writeAll("--seed must be an integer\n");
                try out.flush();
                return;
            };
        } else if (cmd_n < cmd_buf.len) {
            cmd_buf[cmd_n] = t;
            cmd_n += 1;
        }
    }

    const block_size = constants.default_block_size;
    var dev = if (do_format)
        try Device.create(io, image, block_size)
    else
        try Device.open(io, image, block_size);
    defer dev.deinit();

    var cache = try PageCache.init(&dev, gpa, constants.cache_frames);
    defer cache.deinit();

    var g = if (do_format) blk: {
        const world_seed = seed orelse rs: {
            var s: u64 = undefined;
            std.Io.random(io, std.mem.asBytes(&s));
            break :rs s;
        };
        const spawn = deriveSpawn(world_seed);
        break :blk try G.format(gpa, &cache, @intCast(block_size), world_seed, spawn[0], spawn[1]);
    } else try G.open(gpa, &cache, @intCast(block_size));
    defer g.deinit();

    var shell = Shell{ .g = &g, .cache = &cache, .dev = &dev, .out = out };

    // One-shot: run the single command, persist, exit.
    if (cmd_n > 0) {
        var joined: [1024]u8 = undefined;
        var len: usize = 0;
        for (cmd_buf[0..cmd_n], 0..) |tok, i| {
            if (i > 0 and len < joined.len) {
                joined[len] = ' ';
                len += 1;
            }
            const n = @min(tok.len, joined.len - len);
            @memcpy(joined[len .. len + n], tok[0..n]);
            len += n;
        }
        _ = try shell.exec(joined[0..len]);
        try shell.persist();
        try out.flush();
        return;
    }

    try out.print("galaxy: {s}{s}  (type 'help'; 'quit' to save & exit)\n", .{ image, if (do_format) " [new]" else "" });
    try g.render(out);
    try out.flush();

    var editor = zigline.Line.init(gpa, io, .{ .prompt = "galaxy> " });
    defer editor.deinit();
    var raw = zigline.terminal.RawMode.enable() catch {
        try out.writeAll("galaxy: interactive REPL requires a terminal\n");
        try out.flush();
        return;
    };
    defer raw.disable();

    while (try editor.readLine()) |line| {
        defer gpa.free(line);
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len > 0) try editor.historyAdd(line);
        const keep_going = try shell.exec(line);
        try out.flush();
        if (!keep_going) break;
    }

    try shell.persist();
}
