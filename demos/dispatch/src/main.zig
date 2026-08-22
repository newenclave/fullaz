const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");
const dispatch = @import("dispatch");
const zigline = @import("zigline");

const Device = fullaz.device.FileBlock(u32);
const Log = fullaz.device.FileLog(u32);
const Database = fullaz_db.StaticDatabaseWithWal(dispatch.Schema, Device, Log);

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_fw.interface;

    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();
    _ = args_it.skip();
    const image = args_it.next() orelse {
        try out.writeAll("usage: dispatch <image> [--format] [command args...]\n");
        try out.flush();
        return;
    };

    var do_format = false;
    var cmd_buf: [64][]const u8 = undefined;
    var cmd_n: usize = 0;
    var tok = args_it.next();
    if (tok) |t| {
        if (std.mem.eql(u8, t, "--format")) {
            do_format = true;
            tok = args_it.next();
        }
    }
    while (tok) |t| {
        if (cmd_n < cmd_buf.len) {
            cmd_buf[cmd_n] = t;
            cmd_n += 1;
        }
        tok = args_it.next();
    }

    var log_buf: [1024]u8 = undefined;
    const log_path = try std.fmt.bufPrint(&log_buf, "{s}.log", .{image});

    const options: Database.InitOptions = .{
        .image_id = [_]u8{0x44} ** 16,
        .components = .{
            .orders = .{},
            .by_status_due = .{},
            .service_areas = .{},
            .dispatch_queue = .{},
            .audit_log = .{},
            .runbook = .{},
        },
    };

    const device = if (do_format)
        try Device.create(io, image, 512)
    else
        try Device.open(io, image, 512);
    const log = if (do_format)
        try Log.create(io, log_path)
    else
        Log.open(io, log_path) catch try Log.create(io, log_path);

    var database = if (do_format)
        try Database.format(gpa, device, log, options)
    else
        try Database.open(gpa, device, log, options);
    defer database.deinit();

    var shell = dispatch.cli.Cli(Database).init(&database, gpa);

    if (cmd_n > 0) {
        try shell.execTokens(cmd_buf[0..cmd_n], out);
        try out.flush();
        return;
    }

    try out.print("dispatch: {s}{s}  (type 'help'; 'quit' to exit)\n", .{ image, if (do_format) " [formatted]" else "" });
    try out.flush();

    var editor = zigline.Line.init(gpa, io, .{ .prompt = "dispatch> " });
    defer editor.deinit();
    var raw = zigline.terminal.RawMode.enable() catch {
        try out.writeAll("dispatch: interactive REPL requires a terminal\n");
        try out.flush();
        return;
    };
    defer raw.disable();

    while (try editor.readLine()) |line| {
        defer gpa.free(line);
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (std.mem.eql(u8, trimmed, "quit") or std.mem.eql(u8, trimmed, "exit")) {
            break;
        }
        if (trimmed.len > 0) {
            try editor.historyAdd(line);
        }

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const tokens = zigline.tokenize(arena.allocator(), line) catch |err| {
            try out.print("error: {s}\n", .{@errorName(err)});
            continue;
        };
        try shell.execTokens(tokens, out);
        try out.flush();
    }
}
