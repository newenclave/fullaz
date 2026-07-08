const std = @import("std");
const Io = std.Io;
const fullaz = @import("fullaz");
const zigline = @import("zigline");
const fsx = @import("fsx");
const device = fullaz.device;

const constants = fsx.constants;

const Device = device.FileBlock(constants.PageId);
const FileLog = fullaz.storage.wal.FileLog;
const WalT = fullaz.storage.wal.Wal(device.FileLog, constants.PageId, constants.endian);
const PageCache = fullaz.storage.page_cache.PageCacheImpl(Device, fullaz.storage.memory_policy.DefaultMemoryPolicy, WalT);
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
    var dev = if (do_format)
        try Device.create(io, image, block_size)
    else
        try Device.open(io, image, block_size);
    defer dev.deinit();

    // The WAL lives in a sidecar file next to the image; recovery on open (in
    // initWal) replays any transaction committed to the log but not yet applied.
    var wal_path_buf: [1024]u8 = undefined;
    const wal_path = try std.fmt.bufPrint(&wal_path_buf, "{s}.wal", .{image});
    var log = if (do_format)
        try FileLog.create(io, wal_path)
    else
        FileLog.open(io, wal_path) catch try FileLog.create(io, wal_path);
    defer log.deinit();

    const wal = try WalT.init(gpa, &log, block_size);
    var cache = try PageCache.initWal(&dev, gpa, 64, wal);
    defer cache.deinit();

    var fs = if (do_format)
        try FsT.format(&cache, @intCast(block_size))
    else
        try FsT.open(&cache, @intCast(block_size));

    var shell = CliT.init(&fs, gpa);

    if (cmd_n > 0) {
        var wb = try cache.begin();
        errdefer wb.discard() catch {};
        try shell.execTokens(cmd_buf[0..cmd_n], out);
        try out.flush();
        try wb.commit();
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
        var wb = try cache.begin();
        errdefer wb.discard() catch |err| {
            out.print("fsx: error discarding batch: {any}\n", .{err}) catch {};
            out.flush() catch {};
        };
        try shell.exec(line, out);
        try out.flush();
        try wb.commit();
    }
}
