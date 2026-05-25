const std = @import("std");
const skip_list = @import("fullaz").skip_list;
const algorithm = @import("fullaz").core.algorithm;

const PageCacheT = @import("fullaz").storage.page_cache.PageCache;
const device = @import("fullaz").device;

const ModelType = skip_list.models.Paged;
const SkipList = skip_list.List;

fn keyCmp(ctx: anytype, k1: []const u8, k2: []const u8) algorithm.Order {
    return algorithm.cmpSlices(u8, k1, k2, algorithm.CmpNum(u8).asc, ctx) catch .gt;
}

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
        // Persist to disk header, etc.
    }

    pub fn destroyPage(_: *@This(), id: PageId) Error!void {
        _ = id;
        // Implement page destruction logic, e.g., add to free list
    }
};

test "SkipList paged: create and load nodes" {
    const allocator = std.testing.allocator;

    const Device = device.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const Model = ModelType(PageCache, NoneStorageManager, keyCmp, void);

    var dev = try Device.init(allocator, 4096);
    defer dev.deinit();

    var cache = try PageCache.init(&dev, allocator, 16);
    defer cache.deinit();

    var mgr = NoneStorageManager{};

    var prng: std.Random.DefaultPrng = .init(2341);
    const rand = prng.random();

    var model = Model.init(&cache, &mgr, .{ .max_level = 16 }, {}, rand);
    defer model.deinit();
}
