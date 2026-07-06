const std = @import("std");
const fsx = @import("fsx");
const fullaz = @import("fullaz");

const fs = fsx.fs;
const inode = fsx.inode;
const constants = fsx.constants;

const PageCacheT = fullaz.storage.page_cache.PageCache;
const MemoryBlock = fullaz.device.MemoryBlock;

const Device = MemoryBlock(u32);
const PageCache = PageCacheT(Device);
const FsT = fs.Fs(PageCache, fsx.path.Default);

const Collector = struct {
    count: usize = 0,
    saw: [8][]const u8 = undefined,

    fn cb(self: *Collector, name: []const u8, node: inode.Inode) anyerror!void {
        _ = node;
        if (self.count < self.saw.len) {
            self.saw[self.count] = name;
        }
        self.count += 1;
    }

    fn has(self: *const Collector, name: []const u8) bool {
        for (self.saw[0..self.count]) |s| {
            if (std.mem.eql(u8, s, name)) {
                return true;
            }
        }
        return false;
    }
};

fn expectDir(node: ?inode.Inode) !void {
    try std.testing.expect(node != null);
    try std.testing.expectEqual(inode.Kind.dir, std.meta.activeTag(node.?));
}

test "Fs mkdir/resolve: nested directories" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 32);
    defer cache.deinit();

    var f = try FsT.format(&cache, 4096);

    try f.mkdir("/a");
    try f.mkdir("/a/b");
    try f.mkdir("/a/b/c");

    try expectDir(try f.resolve("/"));
    try expectDir(try f.resolve("/a"));
    try expectDir(try f.resolve("/a/b"));
    try expectDir(try f.resolve("/a/b/c"));

    try std.testing.expect((try f.resolve("/a/x")) == null);
    try std.testing.expect((try f.resolve("/nope")) == null);
    try std.testing.expect((try f.resolve("/a/b/c/d")) == null);
}

test "Fs mkdir: error cases" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 32);
    defer cache.deinit();

    var f = try FsT.format(&cache, 4096);
    try f.mkdir("/a");

    try std.testing.expectError(fs.Error.AlreadyExists, f.mkdir("/a"));
    try std.testing.expectError(fs.Error.NotFound, f.mkdir("/x/y"));
    try std.testing.expectError(fs.Error.InvalidPath, f.mkdir("/"));
}

test "Fs ls: lists directory entries" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 32);
    defer cache.deinit();

    var f = try FsT.format(&cache, 4096);
    try f.mkdir("/a");
    try f.mkdir("/a/b");
    try f.mkdir("/a/c");
    try f.mkdir("/a/d");

    var col = Collector{};
    try f.ls("/a", &col, Collector.cb);
    try std.testing.expectEqual(@as(usize, 3), col.count);
    try std.testing.expect(col.has("b"));
    try std.testing.expect(col.has("c"));
    try std.testing.expect(col.has("d"));

    var root_col = Collector{};
    try f.ls("/", &root_col, Collector.cb);
    try std.testing.expectEqual(@as(usize, 1), root_col.count);
    try std.testing.expect(root_col.has("a"));
}

test "Fs mkdir: structure persists across a real reopen" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();

    {
        var cache = try PageCache.init(&device, allocator, 32);
        defer cache.deinit();
        var f = try FsT.format(&cache, 4096);
        try f.mkdir("/a");
        try f.mkdir("/a/b");
        try f.mkdir("/a/b/c");
    }

    {
        var cache = try PageCache.init(&device, allocator, 32);
        defer cache.deinit();
        var f = try FsT.open(&cache, 4096);
        try expectDir(try f.resolve("/a/b/c"));
        try std.testing.expect((try f.resolve("/a/b/z")) == null);
    }
}
