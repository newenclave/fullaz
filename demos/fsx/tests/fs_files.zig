const std = @import("std");
const fsx = @import("fsx");
const fullaz = @import("fullaz");

const fs = fsx.fs;
const inode = fsx.inode;
const constants = fsx.constants;
const superblock = fsx.superblock;

const PageCacheT = fullaz.storage.page_cache.PageCache;
const MemoryBlock = fullaz.device.MemoryBlock;

const Device = MemoryBlock(u32);
const PageCache = PageCacheT(Device);
const FsT = fs.Fs(PageCache, fsx.path.Default);

fn expectFileIndexLeafKind(format_version: u16, expected_kind: u16) !void {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, constants.default_block_size);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 64);
    defer cache.deinit();

    var f = try FsT.format(&cache, constants.default_block_size);
    if (format_version != constants.version) {
        var ph = try cache.fetch(constants.superblock_pid);
        defer ph.deinit();
        var sb = superblock.View(false).init(try ph.dataMut());
        sb.headerMut().version.set(format_version);
        try cache.flush(constants.superblock_pid);
        f = try FsT.open(&cache, constants.default_block_size);
    }

    try f.touch("/f");
    const data = [_]u8{0x5a} ** 10_000;
    _ = try f.write("/f", &data);

    const roots = switch ((try f.resolve("/f")).?) {
        .file => |file_roots| file_roots,
        .dir => unreachable,
    };
    const index_root = roots.index.?;
    var ph = try cache.fetch(index_root);
    defer ph.deinit();
    const page = fullaz.page.header.View(u32, u16, .little, true).init(try ph.data());
    try std.testing.expectEqual(expected_kind, page.header().kind.get());

    var read_back: [10_000]u8 = undefined;
    const read = try f.read("/f", &read_back);
    try std.testing.expectEqual(data.len, read);
    try std.testing.expectEqualSlices(u8, &data, &read_back);
}

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

fn expectFile(node: ?inode.Inode) !void {
    try std.testing.expect(node != null);
    try std.testing.expectEqual(inode.Kind.file, std.meta.activeTag(node.?));
}

test "Fs touch: creates empty file entries" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 32);
    defer cache.deinit();

    var f = try FsT.format(&cache, 4096);

    try f.touch("/f");
    try f.mkdir("/a");
    try f.touch("/a/g");

    const top = (try f.resolve("/f")).?;
    try std.testing.expectEqual(inode.Kind.file, std.meta.activeTag(top));
    try std.testing.expect(top.file.first == null);
    try std.testing.expect(top.file.last == null);
    try std.testing.expect(top.file.index == null);
    try std.testing.expectEqual(@as(u32, 0), top.file.total);

    try expectFile(try f.resolve("/a/g"));
}

test "Fs touch: error cases" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 32);
    defer cache.deinit();

    var f = try FsT.format(&cache, 4096);
    try f.touch("/f");

    try std.testing.expectError(fs.Error.AlreadyExists, f.touch("/f"));
    try std.testing.expectError(fs.Error.NotFound, f.touch("/nope/x"));
    try std.testing.expectError(fs.Error.NotADirectory, f.touch("/f/x"));
    try std.testing.expectError(fs.Error.InvalidPath, f.touch("/"));
}

test "Fs: files and dirs coexist; ls lists both" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 32);
    defer cache.deinit();

    var f = try FsT.format(&cache, 4096);
    try f.mkdir("/a");
    try f.touch("/a/file1");
    try f.mkdir("/a/sub");
    try f.touch("/a/file2");

    var col = Collector{};
    try f.ls("/a", &col, Collector.cb);
    try std.testing.expectEqual(@as(usize, 3), col.count);
    try std.testing.expect(col.has("file1"));
    try std.testing.expect(col.has("sub"));
    try std.testing.expect(col.has("file2"));

    try expectFile(try f.resolve("/a/file1"));
    try std.testing.expectEqual(inode.Kind.dir, std.meta.activeTag((try f.resolve("/a/sub")).?));
}

test "Fs touch: persists across a real reopen" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();

    {
        var cache = try PageCache.init(&device, allocator, 32);
        defer cache.deinit();
        var f = try FsT.format(&cache, 4096);
        try f.mkdir("/d");
        try f.touch("/d/note");
    }

    {
        var cache = try PageCache.init(&device, allocator, 32);
        defer cache.deinit();
        var f = try FsT.open(&cache, 4096);
        try expectFile(try f.resolve("/d/note"));
    }
}

test "Fs write/read: round-trips content and reports size" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 32);
    defer cache.deinit();

    var f = try FsT.format(&cache, 4096);
    try f.touch("/f");

    const data = "hello, fsx world";
    const w = try f.write("/f", data);
    try std.testing.expectEqual(@as(usize, data.len), w);
    try std.testing.expectEqual(@as(u32, data.len), try f.size("/f"));

    var buf: [64]u8 = undefined;
    const r = try f.read("/f", &buf);
    try std.testing.expectEqual(@as(usize, data.len), r);
    try std.testing.expectEqualSlices(u8, data, buf[0..r]);
}

test "Fs write: appends across calls" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 32);
    defer cache.deinit();

    var f = try FsT.format(&cache, 4096);
    try f.touch("/f");

    _ = try f.write("/f", "abc");
    _ = try f.write("/f", "def");
    try std.testing.expectEqual(@as(u32, 6), try f.size("/f"));

    var buf: [16]u8 = undefined;
    const r = try f.read("/f", &buf);
    try std.testing.expectEqualSlices(u8, "abcdef", buf[0..r]);
}

test "Fs replace: overwrites a multi-page file and persists" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();

    {
        var cache = try PageCache.init(&device, allocator, 64);
        defer cache.deinit();
        var f = try FsT.format(&cache, 4096);
        try f.touch("/note.txt");

        const original = [_]u8{0x61} ** 12_000;
        const replacement = [_]u8{0x62} ** 1_500;
        _ = try f.write("/note.txt", &original);
        const written = try f.replace("/note.txt", &replacement);
        try std.testing.expectEqual(replacement.len, written);
        try std.testing.expectEqual(@as(u32, replacement.len), try f.size("/note.txt"));

        var read_back: [replacement.len]u8 = undefined;
        const read = try f.read("/note.txt", &read_back);
        try std.testing.expectEqual(replacement.len, read);
        try std.testing.expectEqualSlices(u8, &replacement, &read_back);
    }

    {
        var cache = try PageCache.init(&device, allocator, 64);
        defer cache.deinit();
        var f = try FsT.open(&cache, 4096);

        const replacement = [_]u8{0x62} ** 1_500;
        var read_back: [replacement.len]u8 = undefined;
        const read = try f.read("/note.txt", &read_back);
        try std.testing.expectEqual(replacement.len, read);
        try std.testing.expectEqualSlices(u8, &replacement, &read_back);
    }
}

test "Fs replace: empty save and regrowth reuse pages" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 64);
    defer cache.deinit();
    var f = try FsT.format(&cache, 4096);
    try f.touch("/note.txt");

    const content = [_]u8{0x63} ** 12_000;
    _ = try f.write("/note.txt", &content);
    const grown_blocks = device.blocksCount();

    try std.testing.expectEqual(@as(usize, 0), try f.replace("/note.txt", ""));
    try std.testing.expectEqual(@as(u32, 0), try f.size("/note.txt"));
    var empty: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try f.read("/note.txt", &empty));

    _ = try f.replace("/note.txt", &content);
    try std.testing.expectEqual(grown_blocks, device.blocksCount());
    var read_back: [content.len]u8 = undefined;
    const read = try f.read("/note.txt", &read_back);
    try std.testing.expectEqual(content.len, read);
    try std.testing.expectEqualSlices(u8, &content, &read_back);
}

test "Fs v2 writes declared file-index page kinds" {
    try expectFileIndexLeafKind(constants.version, constants.PageKind.file_index_leaf);
}

test "Fs v1 remains readable and writes legacy file-index page kinds" {
    try expectFileIndexLeafKind(constants.legacy_version, 0);
}

test "Fs write: large file spanning many chunks round-trips" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 64);
    defer cache.deinit();

    var f = try FsT.format(&cache, 4096);
    try f.mkdir("/a");
    try f.touch("/a/big");

    const data = try allocator.alloc(u8, 20000);
    defer allocator.free(data);
    for (data, 0..) |*b, i| {
        b.* = @truncate(i * 31 + 7);
    }

    const w = try f.write("/a/big", data);
    try std.testing.expectEqual(@as(usize, data.len), w);
    try std.testing.expectEqual(@as(u32, @intCast(data.len)), try f.size("/a/big"));

    const buf = try allocator.alloc(u8, 20000);
    defer allocator.free(buf);
    const r = try f.read("/a/big", buf);
    try std.testing.expectEqual(@as(usize, data.len), r);
    try std.testing.expectEqualSlices(u8, data, buf[0..r]);
}

test "Fs write/read/size: reject directories and missing paths" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 32);
    defer cache.deinit();

    var f = try FsT.format(&cache, 4096);
    try f.mkdir("/d");

    var buf: [8]u8 = undefined;
    try std.testing.expectError(fs.Error.IsADirectory, f.write("/d", "x"));
    try std.testing.expectError(fs.Error.IsADirectory, f.read("/d", &buf));
    try std.testing.expectError(fs.Error.IsADirectory, f.size("/d"));
    try std.testing.expectError(fs.Error.NotFound, f.write("/nope", "x"));
    try std.testing.expectError(fs.Error.NotFound, f.read("/nope", &buf));
}

test "Fs write: content persists across a real reopen" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();

    {
        var cache = try PageCache.init(&device, allocator, 32);
        defer cache.deinit();
        var f = try FsT.format(&cache, 4096);
        try f.mkdir("/d");
        try f.touch("/d/f");
        _ = try f.write("/d/f", "persistent bytes");
    }

    {
        var cache = try PageCache.init(&device, allocator, 32);
        defer cache.deinit();
        var f = try FsT.open(&cache, 4096);
        try std.testing.expectEqual(@as(u32, 16), try f.size("/d/f"));
        var buf: [64]u8 = undefined;
        const r = try f.read("/d/f", &buf);
        try std.testing.expectEqualSlices(u8, "persistent bytes", buf[0..r]);
    }
}
