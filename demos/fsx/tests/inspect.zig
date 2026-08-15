const std = @import("std");
const fsx = @import("fsx");
const fullaz = @import("fullaz");

const Device = fullaz.device.MemoryBlock(u32);
const PageCache = fullaz.storage.page_cache.PageCache(Device);
const FsT = fsx.fs.Fs(PageCache, fsx.path.Default);
const Inspector = fsx.inspect.Inspector(PageCache);

const Counts = struct {
    roles: [@typeInfo(fsx.inspect.PageRole).@"enum".fields.len]usize = [_]usize{0} ** @typeInfo(fsx.inspect.PageRole).@"enum".fields.len,

    fn collect(self: *Counts, info: fsx.inspect.PageInfo) anyerror!void {
        self.roles[@intFromEnum(info.role)] += 1;
    }

    fn get(self: *const Counts, role: fsx.inspect.PageRole) usize {
        return self.roles[@intFromEnum(role)];
    }
};

const OwnershipCounts = struct {
    roles: [@typeInfo(fsx.inspect.OwnershipRole).@"enum".fields.len]usize = [_]usize{0} ** @typeInfo(fsx.inspect.OwnershipRole).@"enum".fields.len,

    fn collect(self: *OwnershipCounts, page: fsx.inspect.OwnedPage) anyerror!void {
        self.roles[@intFromEnum(page.role)] += 1;
    }

    fn get(self: *const OwnershipCounts, role: fsx.inspect.OwnershipRole) usize {
        return self.roles[@intFromEnum(role)];
    }
};

test "Fs inspector classifies live and freed pages" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 64);
    defer cache.deinit();
    var f = try FsT.format(&cache, 4096);
    try f.touch("/f");

    const data = [_]u8{0x44} ** 10_000;
    _ = try f.write("/f", &data);

    var inspector = Inspector.init(&cache);
    var live = Counts{};
    try inspector.scan(fsx.constants.version, &live, Counts.collect);
    try std.testing.expectEqual(@as(usize, 1), live.get(.superblock));
    try std.testing.expect(live.get(.directory_leaf) > 0);
    try std.testing.expect(live.get(.file_chunk) > 0);
    try std.testing.expect(live.get(.file_index_leaf) > 0);

    try f.rm("/f");
    var reclaimed = Counts{};
    try inspector.scan(fsx.constants.version, &reclaimed, Counts.collect);
    try std.testing.expect(reclaimed.get(.freed) > 0);
}

test "Fs inspector traces selected file and directory ownership" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 64);
    defer cache.deinit();
    var f = try FsT.format(&cache, 4096);
    try f.touch("/f");

    const data = [_]u8{0x45} ** 10_000;
    _ = try f.write("/f", &data);

    var file_pages = OwnershipCounts{};
    try f.inspectOwnership("/f", &file_pages, OwnershipCounts.collect);
    try std.testing.expectEqual(@as(usize, 3), file_pages.get(.file_chunk));
    try std.testing.expect(file_pages.get(.file_index) > 0);
    try std.testing.expectEqual(@as(usize, 0), file_pages.get(.directory_tree));

    var directory_pages = OwnershipCounts{};
    try f.inspectOwnership("/", &directory_pages, OwnershipCounts.collect);
    try std.testing.expect(directory_pages.get(.directory_tree) > 0);
    try std.testing.expectEqual(@as(usize, 0), directory_pages.get(.file_chunk));
    try std.testing.expectEqual(@as(usize, 0), directory_pages.get(.file_index));
}

test "Fs inspector traces directory tree children after a split" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 64);
    defer cache.deinit();
    var f = try FsT.format(&cache, 4096);

    for (0..200) |index| {
        var path_buf: [16]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/f{d}", .{index});
        try f.touch(path);
    }

    var pages = OwnershipCounts{};
    try f.inspectOwnership("/", &pages, OwnershipCounts.collect);
    try std.testing.expect(pages.get(.directory_tree) > 1);
}

test "Fs inspector recognizes v1 file-index page kinds" {
    const allocator = std.testing.allocator;
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 64);
    defer cache.deinit();
    var f = try FsT.format(&cache, 4096);

    {
        var handle = try cache.fetch(fsx.constants.superblock_pid);
        defer handle.deinit();
        var sb = fsx.superblock.View(false).init(try handle.dataMut());
        sb.headerMut().version.set(fsx.constants.legacy_version);
        try cache.flush(fsx.constants.superblock_pid);
    }
    f = try FsT.open(&cache, 4096);
    try f.touch("/f");
    const data = [_]u8{0x46} ** 10_000;
    _ = try f.write("/f", &data);

    var inspector = Inspector.init(&cache);
    var counts = Counts{};
    try inspector.scan(fsx.constants.legacy_version, &counts, Counts.collect);
    try std.testing.expect(counts.get(.file_index_leaf) > 0);
}
