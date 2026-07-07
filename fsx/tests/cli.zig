const std = @import("std");
const fsx = @import("fsx");
const fullaz = @import("fullaz");

const fs = fsx.fs;

const PageCacheT = fullaz.storage.page_cache.PageCache;
const MemoryBlock = fullaz.device.MemoryBlock;

const Device = MemoryBlock(u32);
const PageCache = PageCacheT(Device);
const FsT = fs.Fs(PageCache, fsx.path.Default);
const CliT = fsx.cli.Cli(FsT);

const Collector = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,

    pub fn writeAll(self: *Collector, bytes: []const u8) !void {
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }
    pub fn print(self: *Collector, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.bufPrint(self.buf[self.len..], fmt, args);
        self.len += s.len;
    }
    fn reset(self: *Collector) void {
        self.len = 0;
    }
};

fn run(c: *CliT, col: *Collector, line: []const u8) ![]const u8 {
    col.reset();
    try c.exec(line, col);
    return col.buf[0..col.len];
}

test "cli: full session over mkdir/cd/touch/write/cat/ls/stat/rm/rmdir" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 32);
    defer cache.deinit();

    var f = try FsT.format(&cache, 4096);
    var c = CliT.init(&f, allocator);
    var col = Collector{};

    try std.testing.expectEqualStrings("/\n", try run(&c, &col, "pwd"));

    _ = try run(&c, &col, "mkdir /a");
    _ = try run(&c, &col, "mkdir a/b");

    _ = try run(&c, &col, "cd /a");
    try std.testing.expectEqualStrings("/a\n", try run(&c, &col, "pwd"));

    _ = try run(&c, &col, "touch f");
    _ = try run(&c, &col, "write f hello world");
    try std.testing.expectEqualStrings("hello world\n", try run(&c, &col, "cat f"));
    try std.testing.expectEqualStrings("b/\nf\n", try run(&c, &col, "ls"));
    try std.testing.expectEqualStrings("file size=11\n", try run(&c, &col, "stat f"));

    _ = try run(&c, &col, "cd ..");
    try std.testing.expectEqualStrings("/\n", try run(&c, &col, "pwd"));
    try std.testing.expectEqualStrings("a/\n", try run(&c, &col, "ls"));

    _ = try run(&c, &col, "rm /a/f");
    _ = try run(&c, &col, "cd /a");
    try std.testing.expectEqualStrings("b/\n", try run(&c, &col, "ls"));

    _ = try run(&c, &col, "rmdir b");
    try std.testing.expectEqualStrings("", try run(&c, &col, "ls"));
}

test "cli: friendly errors and unknown command" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 32);
    defer cache.deinit();

    var f = try FsT.format(&cache, 4096);
    var c = CliT.init(&f, allocator);
    var col = Collector{};

    _ = try run(&c, &col, "mkdir /a");
    try std.testing.expectEqualStrings("error: AlreadyExists\n", try run(&c, &col, "mkdir /a"));
    try std.testing.expectEqualStrings("error: NotFound\n", try run(&c, &col, "cat /nope"));
    try std.testing.expectEqualStrings("error: IsADirectory\n", try run(&c, &col, "cat /a"));
    try std.testing.expectEqualStrings("unknown command: frob\n", try run(&c, &col, "frob x"));
    try std.testing.expectEqualStrings("", try run(&c, &col, "   "));
}
