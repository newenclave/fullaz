const std = @import("std");
const fullaz = @import("fullaz");

const algorithm = fullaz.core.algorithm;
const fsm = fullaz.storage.fsm;
const PageCacheT = fullaz.storage.page_cache.PageCache;
const device = fullaz.device;
const skip_list = fullaz.skip_list;

const SizePolicy = struct {
    pub const SizeClass = u16;
    pub const maximum_class_count: usize = 256;

    pub fn getSizeClass(_: *const @This(), size: SizeClass) SizeClass {
        return size >> 8;
    }

    pub fn count(_: *const @This()) usize {
        return 256;
    }
};

const maximum_level = 4;
const SkipState = skip_list.models.paged.State(u32, maximum_level, .little);
const FsmState = fsm.models.paged.slab.State(u32, SizePolicy, .little);
const StorageState = extern struct {
    skip: SkipState = .{},
    fsm: FsmState = .{},
};

const StorageManager = struct {
    pub const PageId = u32;
    pub const Error = error{};
    pub const StateLeaseType = struct {
        pub const Error = error{};

        value: *StorageState,

        pub fn data(self: *const @This()) @This().Error![]const u8 {
            return std.mem.asBytes(@as(*const StorageState, self.value));
        }

        pub fn dataMut(self: *@This()) @This().Error![]u8 {
            return std.mem.asBytes(self.value);
        }

        pub fn finish(_: *@This()) void {}
        pub fn deinit(_: *@This()) void {}
    };

    state_data: StorageState = .{},

    pub fn state(self: *@This()) Error!StateLeaseType {
        return .{ .value = &self.state_data };
    }

    pub fn destroyPage(_: *@This(), _: u32) Error!void {}
};

const SkipStorageManager = fullaz.core.storage_manager.FieldStorageManager(
    StorageManager,
    StorageState,
    "skip",
);
const FsmStorageManager = fullaz.core.storage_manager.PagedFieldStorageManager(
    StorageManager,
    StorageState,
    "fsm",
);

fn keyCmp(_: void, left: []const u8, right: []const u8) std.math.Order {
    return switch (algorithm.cmpSlices(u8, left, right, algorithm.CmpNum(u8).asc, {}) catch .gt) {
        .lt => .lt,
        .eq => .eq,
        .gt, .unordered => .gt,
    };
}

test "paged SkipList tracks node pages through paged FSM header locations" {
    const allocator = std.testing.allocator;
    const Device = device.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const LocationTrait = fsm.location.Trait(u32, u16, .little);
    const LinksTrait = fullaz.page.links.Trait(u32, .little);
    const Additional = fullaz.page.extensions.Compose(.{
        .version = 2,
        .fields = .{
            fullaz.page.extensions.field("fsm", LocationTrait),
            fullaz.page.extensions.field("links", LinksTrait),
        },
    });
    const LocationAccessor = fsm.HeaderLocationAccessor(u32, u16, .little, Additional, "fsm");
    const FsmModel = fsm.models.paged.slab.Model(PageCache, FsmStorageManager, SizePolicy, LocationAccessor);
    const Fsm = fsm.Fsm(FsmModel);
    const SkipModel = skip_list.models.Paged(
        PageCache,
        SkipStorageManager,
        maximum_level,
        Fsm,
        Additional,
        keyCmp,
        void,
    );
    const SkipList = skip_list.List(SkipModel);
    const HeaderViewMut = fullaz.page.header.ViewImpl(u32, u16, Additional, .little, false);
    const HeaderViewConst = fullaz.page.header.ViewImpl(u32, u16, Additional, .little, true);

    var dev = try Device.init(allocator, 4096);
    defer dev.deinit();
    var cache = try PageCache.init(&dev, allocator, 32);
    defer cache.deinit();
    var storage = StorageManager{};
    var fsm_storage = FsmStorageManager.init(&storage);
    var skip_storage = SkipStorageManager.init(&storage);
    var fsm_model = FsmModel.init(&cache, &fsm_storage, SizePolicy{}, .{ .page_kind = 91 });
    var fsm_index = Fsm.init(&fsm_model);
    defer fsm_index.deinit();

    var prng = std.Random.DefaultPrng.init(0xF5A_51A7);
    var model = SkipModel.init(
        &cache,
        &skip_storage,
        &fsm_index,
        .{
            .key_len = 4,
            .value_len = 4,
            .node_page_kind = 42,
        },
        {},
        prng.random(),
        allocator,
    );
    defer model.deinit();
    var list = SkipList.init(&model);
    defer list.deinit();

    try list.insert("AAAA", "1111");
    try list.insert("BBBB", "2222");
    try list.insert("CCCC", "3333");

    const data_page_id = (try model.accessor().getRoot(0)).?.page_id;
    const skip_root_before = (try model.accessor().getRoot(0)).?;
    try std.testing.expectEqual(@as(?u32, data_page_id), try fsm_index.find(1));
    {
        var ph = try cache.fetch(data_page_id);
        defer ph.deinit();
        try std.testing.expect((try LocationAccessor.read(try ph.data())) != null);
    }
    {
        var ph = try cache.fetch(data_page_id);
        defer ph.deinit();
        var page_view = HeaderViewMut.init(try ph.dataMut());
        const links = Additional.fieldMut(page_view.additionalMut(), "links");
        LinksTrait.setPrev(links, 11);
        LinksTrait.setNext(links, 22);
    }

    try list.remove("BBBB");
    try std.testing.expect(!(try list.contains("BBBB")));

    try list.insert("DDDD", "4444");
    try std.testing.expect(try list.contains("DDDD"));
    try std.testing.expectEqual(skip_root_before, (try model.accessor().getRoot(0)).?);
    try std.testing.expectEqual(@as(?u32, data_page_id), try fsm_index.find(1));
    {
        var ph = try cache.fetch(data_page_id);
        defer ph.deinit();
        try std.testing.expect((try LocationAccessor.read(try ph.data())) != null);
        const page_view = HeaderViewConst.init(try ph.data());
        const links = Additional.field(page_view.additional(), "links");
        try std.testing.expectEqual(@as(?u32, 11), LinksTrait.getPrev(links));
        try std.testing.expectEqual(@as(?u32, 22), LinksTrait.getNext(links));
    }
}
