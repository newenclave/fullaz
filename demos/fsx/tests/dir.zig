const std = @import("std");
const fsx = @import("fsx");
const fullaz = @import("fullaz");

const dir = fsx.dir;
const inode = fsx.inode;
const constants = fsx.constants;

const PageCacheT = fullaz.storage.page_cache.PageCache;
const MemoryBlock = fullaz.device.MemoryBlock;
const PageId = constants.PageId;

test "Directory: insert/lookup/remove dir and file entries" {
    const allocator = std.testing.allocator;
    const Device = MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const Dir = dir.Directory(PageCache);

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 16);
    defer cache.deinit();

    var d = Dir.init(&cache, null);
    try std.testing.expect(d.getRoot() == null);

    _ = try d.insert("photos", inode.Inode.newDir());
    try std.testing.expect(d.getRoot() != null);

    _ = try d.insert("notes.txt", .{ .file = .{ .first = 5, .last = 9, .total = 100, .index = 12 } });

    const photos = (try d.lookup("photos")).?;
    try std.testing.expectEqual(inode.Kind.dir, std.meta.activeTag(photos));
    try std.testing.expect(photos.dir.root == null);

    const notes = (try d.lookup("notes.txt")).?;
    try std.testing.expectEqual(inode.Kind.file, std.meta.activeTag(notes));
    try std.testing.expectEqual(@as(?PageId, 5), notes.file.first);
    try std.testing.expectEqual(@as(?PageId, 9), notes.file.last);
    try std.testing.expectEqual(@as(u32, 100), notes.file.total);
    try std.testing.expectEqual(@as(?PageId, 12), notes.file.index);

    try std.testing.expect((try d.lookup("missing")) == null);

    try std.testing.expect(try d.remove("photos"));
    try std.testing.expect((try d.lookup("photos")) == null);
    try std.testing.expect((try d.lookup("notes.txt")) != null);
}

test "Directory: many entries force splits; all findable, root persists" {
    const allocator = std.testing.allocator;
    const Device = MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const Dir = dir.Directory(PageCache);

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 32);
    defer cache.deinit();

    var d = Dir.init(&cache, null);

    const N: u32 = 100;
    var namebuf: [16]u8 = undefined;

    var i: u32 = 0;
    while (i < N) : (i += 1) {
        const name = try std.fmt.bufPrint(&namebuf, "file{d:0>4}", .{i});
        _ = try d.insert(name, .{ .file = .{ .first = i, .total = i * 10 } });
    }
    try std.testing.expect(d.getRoot() != null);

    i = 0;
    while (i < N) : (i += 1) {
        const name = try std.fmt.bufPrint(&namebuf, "file{d:0>4}", .{i});
        const node = (try d.lookup(name)).?;
        try std.testing.expectEqual(@as(?PageId, i), node.file.first);
        try std.testing.expectEqual(@as(u32, i * 10), node.file.total);
    }

    i = 0;
    while (i < N) : (i += 2) {
        const name = try std.fmt.bufPrint(&namebuf, "file{d:0>4}", .{i});
        try std.testing.expect(try d.remove(name));
    }

    i = 0;
    while (i < N) : (i += 1) {
        const name = try std.fmt.bufPrint(&namebuf, "file{d:0>4}", .{i});
        const found = (try d.lookup(name)) != null;
        try std.testing.expectEqual(i % 2 == 1, found);
    }
}

test "Directory: rejects names longer than max_name_len" {
    const allocator = std.testing.allocator;
    const Device = MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const Dir = dir.Directory(PageCache);

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();

    var d = Dir.init(&cache, null);

    var long: [constants.max_name_len + 1]u8 = undefined;
    @memset(&long, 'x');
    try std.testing.expectError(dir.Error.NameTooLong, d.insert(&long, inode.Inode.newDir()));
}
