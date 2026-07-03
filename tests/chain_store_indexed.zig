const std = @import("std");
const fullaz = @import("fullaz");
const wbpt = fullaz.weighted_bpt;
const PageCacheT = fullaz.storage.page_cache.PageCache;
const dev = fullaz.device;
const chain_index = fullaz.storage.chain_store.weighted_index;

const IndexEntry = chain_index.IndexEntry;
const IndexValuePolicy = chain_index.IndexValuePolicy;
const PagedModel = wbpt.models.paged.PagedModel;

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

    const Model = PagedModel(PageCache, NoneStorageManager, Policy);
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
