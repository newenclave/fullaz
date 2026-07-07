const std = @import("std");
const Io = std.Io;
const fullaz = @import("fullaz");
const zigline = @import("zigline");
const fsx = @import("fsx");

const constants = fsx.constants;

const Device = fullaz.device.FileBlock(constants.PageId);
const PageCache = fullaz.storage.page_cache.PageCache(Device);
const FsT = fsx.fs.Fs(PageCache, fsx.path.Default);
const CliT = fsx.cli.Cli(FsT);

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_fw.interface;

    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();
    _ = args_it.skip();
    const image = args_it.next() orelse {
        try out.writeAll("usage: fsx <image> [--format] [command args...]\n");
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

    const block_size = constants.default_block_size;
    var device = if (do_format)
        try Device.create(io, image, block_size)
    else
        try Device.open(io, image, block_size);
    defer device.deinit();

    var cache = try PageCache.init(&device, gpa, 64);
    defer cache.deinit();

    var fs = if (do_format)
        try FsT.format(&cache, @intCast(block_size))
    else
        try FsT.open(&cache, @intCast(block_size));

    var shell = CliT.init(&fs, gpa);

    if (cmd_n > 0) {
        try shell.execTokens(cmd_buf[0..cmd_n], out);
        try out.flush();
        try cache.flushAll();
        return;
    }

    try out.print("fsx: {s}{s}  (type 'help'; 'quit' to exit)\n", .{ image, if (do_format) " [formatted]" else "" });
    try out.flush();

    var editor = zigline.Line.init(gpa, io, .{ .prompt = "fsx> " });
    defer editor.deinit();
    var raw = zigline.terminal.RawMode.enable() catch {
        try out.writeAll("fsx: interactive REPL requires a terminal\n");
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
        try shell.exec(line, out);
        try out.flush();
        try cache.flushAll();
    }
}
