const std = @import("std");
const fullaz = @import("fullaz");
const wbpt = fullaz.weighted_bpt;
const PageCacheT = fullaz.storage.page_cache.PageCache;
const dev = fullaz.device;
const chain_index = fullaz.storage.chain_store.weighted_index;

const IndexEntry = chain_index.IndexEntry;
const IndexValuePolicy = chain_index.IndexValuePolicy;
const WeightedIndex = chain_index.WeightedIndex;
const PagedModel = wbpt.models.paged.PagedModel;

const IndexSM = struct {
    const Self = @This();
    pub const Error = error{};
    pub const PageId = u32;
    pub const Size = u64;

    index_root: ?u32 = null,
    last: ?u32 = null,

    pub fn getIndexRoot(self: *const Self) ?u32 {
        return self.index_root;
    }
    pub fn setIndexRoot(self: *Self, root: ?u32) Error!void {
        self.index_root = root;
    }
    pub fn getLast(self: *const Self) Error!?u32 {
        return self.last;
    }
    pub fn destroyPage(self: *Self, id: PageId) Error!void {
        _ = self;
        _ = id;
    }
};

const NoneStorageManager = struct {
    pub const Self = @This();
    pub const PageId = u32;
    pub const Error = error{};

    root_block_id: ?u32 = null,

    pub fn getRoot(self: *const @This()) ?u32 {
        return self.root_block_id;
    }
    pub fn setRoot(self: *@This(), root: ?u32) Error!void {
        self.root_block_id = root;
    }
    pub fn destroyPage(_: *@This(), id: PageId) Error!void {
        _ = id;
    }
};

test "chain index: IndexValuePolicy makes weight = chunk size (not value.len)" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    // The custom policy is what makes this a chunk-offset index rather than a
    // byte container.
    const Policy = IndexValuePolicy(u32, u32, .little);
    const Entry = IndexEntry(u32, u32, .little);

    const Model = PagedModel(PageCache, NoneStorageManager, u32, Policy);
    const Tree = wbpt.WeightedBpt(Model);

    var store_mgr = NoneStorageManager{};
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 16);
    defer cache.deinit();
    var model = Model.init(&cache, &store_mgr, .{});
    var tree = Tree.init(&model, .neighbor_share);
    defer tree.deinit();

    // three chunks: distinct page ids and (importantly) distinct sizes
    var a: [@sizeOf(Entry)]u8 = undefined;
    var b: [@sizeOf(Entry)]u8 = undefined;
    var c: [@sizeOf(Entry)]u8 = undefined;

    var entry_a: *Entry = @ptrCast(&a);
    var entry_b: *Entry = @ptrCast(&b);
    var entry_c: *Entry = @ptrCast(&c);

    entry_a.page_id.set(100);
    entry_a.size.set(1000);

    entry_b.page_id.set(101);
    entry_b.size.set(500);

    entry_c.page_id.set(102);
    entry_c.size.set(2000);

    _ = try tree.insert(0, &a); // [0, 1000)
    _ = try tree.insert(1000, &b); // [1000, 1500)
    _ = try tree.insert(1500, &c); // [1500, 3500)

    // The decisive check: total weight is the sum of chunk SIZES (3500), not the
    // sum of the stored value lengths (3 * 8 = 24). Proves weight() drives it.
    try std.testing.expectEqual(@as(u32, 3500), try tree.totalWeight());

    var buf: [@sizeOf(Entry)]u8 = undefined;
    const cases = [_]struct { off: u32, pid: u32, intra: u32 }{
        .{ .off = 0, .pid = 100, .intra = 0 },
        .{ .off = 500, .pid = 100, .intra = 500 },
        .{ .off = 1000, .pid = 101, .intra = 0 }, // boundary -> next chunk
        .{ .off = 1200, .pid = 101, .intra = 200 },
        .{ .off = 1500, .pid = 102, .intra = 0 },
        .{ .off = 3000, .pid = 102, .intra = 1500 },
    };
    for (cases) |case| {
        const r = (try tree.findByWeight(case.off, &buf)).?;
        const entry: *const Entry = @ptrCast(buf[0..r.value_len].ptr);
        try std.testing.expectEqual(case.pid, entry.page_id.get());
        try std.testing.expectEqual(case.intra, r.intra_weight);
    }

    // at or beyond the end -> null
    try std.testing.expect((try tree.findByWeight(3500, &buf)) == null);
}

test "chain WeightedIndex: seal/unseal + derived-tail locate" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const Index = WeightedIndex(PageCache, IndexSM, .little);

    var sm = IndexSM{};
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 16);
    defer cache.deinit();

    var idx = Index.init(&cache, &sm, .{});
    defer idx.deinit();

    // No chunks at all -> nothing to locate, root slot untouched.
    try std.testing.expect((try idx.locate(0)) == null);
    try std.testing.expect(sm.getIndexRoot() == null);

    // Chain has one active chunk (102) but nothing sealed yet: every offset maps
    // to the derived tail chunk, starting at 0.
    sm.last = 102;
    {
        const loc = (try idx.locate(0)).?;
        try std.testing.expectEqual(@as(u32, 102), loc.page_id);
        try std.testing.expectEqual(@as(u64, 0), loc.chunk_start);
    }

    // Now grow the chain: 100 then 101 fill up and get sealed (each becomes
    // non-last as the next chunk is linked). 102 remains the active tail.
    try idx.onSeal(100, 1000); // sealed [0, 1000)
    try idx.onSeal(101, 500); // sealed [1000, 1500)
    // Sealing created the tree, so the root now persists in the SM.
    try std.testing.expect(sm.getIndexRoot() != null);

    // Sealed offsets resolve via the tree; offsets >= 1500 fall in the derived
    // tail (102), whose start is exactly the sealed total (1500).
    const cases = [_]struct { off: u64, pid: u32, start: u64 }{
        .{ .off = 0, .pid = 100, .start = 0 },
        .{ .off = 500, .pid = 100, .start = 0 },
        .{ .off = 999, .pid = 100, .start = 0 },
        .{ .off = 1000, .pid = 101, .start = 1000 }, // boundary -> next sealed chunk
        .{ .off = 1499, .pid = 101, .start = 1000 },
        .{ .off = 1500, .pid = 102, .start = 1500 }, // sealed total -> tail
        .{ .off = 5000, .pid = 102, .start = 1500 }, // anywhere past -> tail start
    };
    for (cases) |c| {
        const loc = (try idx.locate(c.off)).?;
        try std.testing.expectEqual(c.pid, loc.page_id);
        try std.testing.expectEqual(c.start, loc.chunk_start);
    }

    // Unseal the last sealed chunk (101 becomes the active tail again, mirroring
    // a popChunk). Now only 100 is sealed; 101 is the derived tail at 1000.
    try idx.onUnseal();
    sm.last = 101;
    {
        const loc = (try idx.locate(1000)).?;
        try std.testing.expectEqual(@as(u32, 101), loc.page_id);
        try std.testing.expectEqual(@as(u64, 1000), loc.chunk_start);
        const loc0 = (try idx.locate(0)).?;
        try std.testing.expectEqual(@as(u32, 100), loc0.page_id);
        try std.testing.expectEqual(@as(u64, 0), loc0.chunk_start);
    }

    // clear() empties the tree; with 101 still the active chunk, all offsets map
    // to the tail starting at 0.
    try idx.clear();
    {
        const loc = (try idx.locate(0)).?;
        try std.testing.expectEqual(@as(u32, 101), loc.page_id);
        try std.testing.expectEqual(@as(u64, 0), loc.chunk_start);
    }
}

const chain_store = fullaz.storage.chain_store;

const FullSM = struct {
    const Self = @This();
    pub const PageId = u32;
    pub const Size = u32;
    pub const Error = error{};

    first: ?u32 = null,
    last: ?u32 = null,
    total: u32 = 0,
    index_root: ?u32 = null,

    pub fn getTotalSize(self: *const Self) Error!Size {
        return self.total;
    }
    pub fn setTotalSize(self: *Self, size: Size) Error!void {
        self.total = size;
    }
    pub fn getFirst(self: *const Self) Error!?PageId {
        return self.first;
    }
    pub fn getLast(self: *const Self) Error!?PageId {
        return self.last;
    }
    pub fn setFirst(self: *Self, id: ?PageId) Error!void {
        self.first = id;
    }
    pub fn setLast(self: *Self, id: ?PageId) Error!void {
        self.last = id;
    }
    pub fn destroyPage(self: *Self, id: PageId) Error!void {
        _ = self;
        _ = id;
    }
    pub fn getIndexRoot(self: *const Self) ?PageId {
        return self.index_root;
    }
    pub fn setIndexRoot(self: *Self, root: ?PageId) Error!void {
        self.index_root = root;
    }
};

const GtChunk = struct { start: u32, pid: u32, size: u32 };

fn walkChunks(hdl: anytype, out: []GtChunk) !usize {
    var cur = try hdl.begin();
    defer cur.deinit();
    var n: usize = 0;
    var off: u32 = 0;
    while (true) {
        const sz: u32 = @intCast(try cur.currentDataSize());
        out[n] = .{ .start = off, .pid = try cur.pid(), .size = sz };
        n += 1;
        off += sz;
        if (try cur.hasNext()) {
            try cur.moveNext();
        } else break;
    }
    return n;
}

/// Assert the index-based getPosition(off) equals the ground-truth chunk.
fn expectPos(hdl: anytype, chunks: []const GtChunk, off: u32) !void {
    var exp_pid: u32 = 0;
    var exp_intra: u32 = 0;
    var found = false;
    for (chunks) |c| {
        if (off >= c.start and off < c.start + c.size) {
            exp_pid = c.pid;
            exp_intra = off - c.start;
            found = true;
            break;
        }
    }
    try std.testing.expect(found);

    const pos = try hdl.getPosition(off);
    try std.testing.expect(pos.page_id != null);
    try std.testing.expectEqual(exp_pid, pos.page_id.?);
    try std.testing.expectEqual(@as(u16, @intCast(exp_intra)), pos.pos);
}

test "chain HandleWeighted: getPosition matches a linear walk over a large file" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const Handle = chain_store.HandleWeighted(PageCache, FullSM, .little);

    var sm = FullSM{};
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 32);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &sm, .{});
    defer hdl.deinit();
    try hdl.create();

    // A buffer big enough to span many chunks.
    var data: [20000]u8 = undefined;
    for (&data, 0..) |*b, i| {
        b.* = @truncate(i * 31 + 7);
    }
    const written = try hdl.write(&data);
    try std.testing.expectEqual(@as(usize, data.len), written);
    try std.testing.expectEqual(@as(u32, data.len), try hdl.totalSize());

    // Writing sealed several chunks, so the index root must now be persisted.
    try std.testing.expect(sm.getIndexRoot() != null);

    var chunks: [128]GtChunk = undefined;
    const n = try walkChunks(&hdl, &chunks);
    try std.testing.expect(n > 1); // genuinely multi-chunk
    var sum: u32 = 0;
    for (chunks[0..n]) |c| sum += c.size;
    try std.testing.expectEqual(@as(u32, data.len), sum);

    // Exercise the index DIRECTLY (not getPosition's linear fallback, which would
    // mask a dead index): a sealed chunk resolves via the tree, the last chunk
    // via the derived tail.
    {
        const loc0 = (try hdl.index.locate(chunks[0].start + 1)).?; // sealed (n>1)
        try std.testing.expectEqual(chunks[0].pid, loc0.page_id);
        try std.testing.expectEqual(chunks[0].start, loc0.chunk_start);

        const tail = chunks[n - 1];
        const loct = (try hdl.index.locate(tail.start)).?; // active tail
        try std.testing.expectEqual(tail.pid, loct.page_id);
        try std.testing.expectEqual(tail.start, loct.chunk_start);
    }

    // Sweep offsets + every chunk boundary + last byte.
    var off: u32 = 0;
    while (off < data.len) : (off += 137) {
        try expectPos(&hdl, chunks[0..n], off);
    }
    for (chunks[0..n]) |c| {
        try expectPos(&hdl, chunks[0..n], c.start);
        if (c.size > 0) try expectPos(&hdl, chunks[0..n], c.start + c.size - 1);
    }
    try expectPos(&hdl, chunks[0..n], data.len - 1);

    // Round-trip the bytes through the get cursor (setg uses getPosition).
    try hdl.setg(0);
    var rbuf: [20000]u8 = undefined;
    const rd = try hdl.read(&rbuf);
    try std.testing.expectEqual(@as(usize, data.len), rd);
    try std.testing.expectEqualSlices(u8, &data, &rbuf);
}

test "chain HandleWeighted: getPosition stays correct after truncate (onUnseal)" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const Handle = chain_store.HandleWeighted(PageCache, FullSM, .little);

    var sm = FullSM{};
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 32);
    defer cache.deinit();

    var hdl = Handle.init(&cache, &sm, .{});
    defer hdl.deinit();
    try hdl.create();

    var data: [20000]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i * 17 + 3);
    _ = try hdl.write(&data);

    // Drop the last 15000 bytes: this pops full chunks (each onUnseal) and shrinks
    // the tail, leaving a still-multi-chunk file.
    try hdl.truncate(15000);
    try std.testing.expectEqual(@as(u32, 5000), try hdl.totalSize());

    var chunks: [128]GtChunk = undefined;
    const n = try walkChunks(&hdl, &chunks);
    var sum: u32 = 0;
    for (chunks[0..n]) |c| sum += c.size;
    try std.testing.expectEqual(@as(u32, 5000), sum);

    // Index-based getPosition must still match the (freshly walked) ground truth.
    var off: u32 = 0;
    while (off < 5000) : (off += 91) {
        try expectPos(&hdl, chunks[0..n], off);
    }
    for (chunks[0..n]) |c| {
        try expectPos(&hdl, chunks[0..n], c.start);
        if (c.size > 0) try expectPos(&hdl, chunks[0..n], c.start + c.size - 1);
    }
}
