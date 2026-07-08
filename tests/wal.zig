const std = @import("std");
const fullaz = @import("fullaz");
const wal = fullaz.storage.wal;

const testing = std.testing;

const PAGE = 8;
const Wal = wal.Wal(wal.MemoryLog, u32, .little);

const Collector = struct {
    pids: [16]u32 = undefined,
    first: [16]u8 = undefined,
    n: usize = 0,

    fn cb(self: *Collector, pid: u32, bytes: []const u8) anyerror!void {
        self.pids[self.n] = pid;
        self.first[self.n] = bytes[0];
        self.n += 1;
    }
};

fn page(byte: u8) [PAGE]u8 {
    return .{byte} ** PAGE;
}

test "WAL: replay yields committed pages in order" {
    const a = testing.allocator;
    var log = try wal.MemoryLog.init(a);
    defer log.deinit();
    var w = try Wal.init(a, &log, PAGE);
    defer w.deinit();

    try w.appendPage(5, &page(0xAA));
    try w.appendPage(9, &page(0xBB));
    try w.sealCommit(2);

    var col = Collector{};
    try w.replay(&col, Collector.cb);
    try testing.expectEqual(@as(usize, 2), col.n);
    try testing.expectEqual(@as(u32, 5), col.pids[0]);
    try testing.expectEqual(@as(u32, 9), col.pids[1]);
    try testing.expectEqual(@as(u8, 0xAA), col.first[0]);
    try testing.expectEqual(@as(u8, 0xBB), col.first[1]);
}

test "WAL: an uncommitted trailing txn is ignored on replay" {
    const a = testing.allocator;
    var log = try wal.MemoryLog.init(a);
    defer log.deinit();
    var w = try Wal.init(a, &log, PAGE);
    defer w.deinit();

    try w.appendPage(1, &page(0x11));
    try w.sealCommit(1);
    // A second transaction's pages, but no commit record (crash before sealCommit).
    try w.appendPage(2, &page(0x22));

    var col = Collector{};
    try w.replay(&col, Collector.cb);
    try testing.expectEqual(@as(usize, 1), col.n);
    try testing.expectEqual(@as(u32, 1), col.pids[0]);
}

test "WAL: an unsynced tail is lost after a crash" {
    const a = testing.allocator;
    var log = try wal.MemoryLog.init(a);
    defer log.deinit();

    {
        var w = try Wal.init(a, &log, PAGE);
        defer w.deinit();
        try w.appendPage(1, &page(0x11));
        try w.sealCommit(1); // durable (sync)
        // A second transaction appended but never sealed (no sync).
        try w.appendPage(2, &page(0x22));
    }
    // Crash: everything past the last sync() is gone.
    log.buf.shrinkRetainingCapacity(log.synced);

    var w2 = try Wal.init(a, &log, PAGE);
    defer w2.deinit();
    var col = Collector{};
    try w2.replay(&col, Collector.cb);
    try testing.expectEqual(@as(usize, 1), col.n);
    try testing.expectEqual(@as(u32, 1), col.pids[0]);
}

test "WAL: checkpoint empties the log" {
    const a = testing.allocator;
    var log = try wal.MemoryLog.init(a);
    defer log.deinit();
    var w = try Wal.init(a, &log, PAGE);
    defer w.deinit();

    try w.appendPage(1, &page(0x11));
    try w.sealCommit(1);
    try testing.expect(log.size() > 0);

    try w.checkpoint();
    try testing.expectEqual(@as(usize, 0), log.size());

    var col = Collector{};
    try w.replay(&col, Collector.cb);
    try testing.expectEqual(@as(usize, 0), col.n);
}

test "WAL: a CRC-corrupt record is dropped on replay" {
    const a = testing.allocator;
    var log = try wal.MemoryLog.init(a);
    defer log.deinit();
    var w = try Wal.init(a, &log, PAGE);
    defer w.deinit();

    try w.appendPage(1, &page(0x11));
    try w.sealCommit(1);
    // Flip a payload byte (payload begins right after the page-record header).
    log.buf.items[Wal.page_header_len] ^= 0xFF;

    var col = Collector{};
    try w.replay(&col, Collector.cb);
    try testing.expectEqual(@as(usize, 0), col.n);
}

const Dev = fullaz.device.MemoryBlock(u32);
const DefaultPolicy = fullaz.storage.memory_policy.DefaultMemoryPolicy;
const WalT = wal.Wal(wal.MemoryLog, u32, .little);
const WalCache = fullaz.storage.page_cache.PageCacheImpl(Dev, DefaultPolicy, WalT);
const BLOCK = 64;

test "WAL cache: commit applies to home and checkpoints the log" {
    const a = testing.allocator;
    var dev = try Dev.init(a, BLOCK);
    defer dev.deinit();
    var log = try wal.MemoryLog.init(a);
    defer log.deinit();

    const w = try WalT.init(a, &log, dev.blockSize());
    var cache = try WalCache.initWal(&dev, a, 8, w);
    defer cache.deinit();

    var wb = try cache.begin();
    {
        var h = try cache.create(); // pid 0
        defer h.deinit();
        (try h.getDataMut())[0] = 0xAB;
    }
    try wb.commit();

    // The page reached the home device...
    var buf: [BLOCK]u8 = undefined;
    try dev.readBlock(0, &buf);
    try testing.expectEqual(@as(u8, 0xAB), buf[0]);
    // ...and the log was checkpointed (empty) after commit.
    try testing.expectEqual(@as(usize, 0), log.size());
}

test "WAL cache: recovery redoes a committed txn from the log" {
    const a = testing.allocator;
    var dev = try Dev.init(a, BLOCK);
    defer dev.deinit();
    var log = try wal.MemoryLog.init(a);
    defer log.deinit();

    // Hand-build a committed WAL transaction for page 0 WITHOUT touching the
    // device: models a crash after the WAL commit but before the home apply.
    {
        var w = try WalT.init(a, &log, dev.blockSize());
        defer w.deinit();
        try w.appendPage(0, &([_]u8{0xCD} ** BLOCK));
        try w.sealCommit(1);
    }
    try testing.expect(log.size() > 0);
    try testing.expectEqual(@as(usize, 0), dev.blocksCount());

    // Reopen: recovery must replay the committed page into the device.
    const w2 = try WalT.init(a, &log, dev.blockSize());
    var cache = try WalCache.initWal(&dev, a, 8, w2);
    defer cache.deinit();

    try testing.expectEqual(@as(usize, 1), dev.blocksCount());
    var buf: [BLOCK]u8 = undefined;
    try dev.readBlock(0, &buf);
    try testing.expectEqual(@as(u8, 0xCD), buf[0]);
    try testing.expectEqual(@as(usize, 0), log.size()); // checkpointed after recovery
}

test "WAL cache: recovery ignores an uncommitted txn" {
    const a = testing.allocator;
    var dev = try Dev.init(a, BLOCK);
    defer dev.deinit();
    var log = try wal.MemoryLog.init(a);
    defer log.deinit();

    // Page records but no commit record (crash before sealCommit).
    {
        var w = try WalT.init(a, &log, dev.blockSize());
        defer w.deinit();
        try w.appendPage(0, &([_]u8{0xEE} ** BLOCK));
    }

    const w2 = try WalT.init(a, &log, dev.blockSize());
    var cache = try WalCache.initWal(&dev, a, 8, w2);
    defer cache.deinit();

    // Nothing committed -> nothing applied; the log is reset.
    try testing.expectEqual(@as(usize, 0), dev.blocksCount());
    try testing.expectEqual(@as(usize, 0), log.size());
}

test "WAL: FileLog round-trips across a reopen" {
    const io = std.testing.io;
    const path = ".zig-cache/wal_filelog.log";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const FileWal = wal.Wal(wal.FileLog, u32, .little);

    {
        var log = try wal.FileLog.create(io, path);
        defer log.deinit();
        var w = try FileWal.init(testing.allocator, &log, PAGE);
        defer w.deinit();
        try w.appendPage(7, &page(0x7E));
        try w.sealCommit(1);
    }
    {
        var log = try wal.FileLog.open(io, path);
        defer log.deinit();
        var w = try FileWal.init(testing.allocator, &log, PAGE);
        defer w.deinit();
        var col = Collector{};
        try w.replay(&col, Collector.cb);
        try testing.expectEqual(@as(usize, 1), col.n);
        try testing.expectEqual(@as(u32, 7), col.pids[0]);
        try testing.expectEqual(@as(u8, 0x7E), col.first[0]);
    }
}
