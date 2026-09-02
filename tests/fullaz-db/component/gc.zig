const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

const Device = fullaz.device.MemoryBlock(u32);
const RawCache = fullaz.storage.page_cache.PageCache(Device);
const Cache = fullaz_db.MemoryReclaimingCache(RawCache);

const Backend = struct {
    pub const PageId = u32;
    pub const CacheType = Cache;

    allocator_value: std.mem.Allocator,
    cache_ptr: *Cache,

    pub fn allocator(self: *const @This()) std.mem.Allocator {
        return self.allocator_value;
    }

    pub fn cache(self: *@This()) *Cache {
        return self.cache_ptr;
    }
};

const TestCollector = struct {
    const Self = @This();

    pub const PageId = u32;
    pub const ScannerVersion = u32;
    pub const Error = error{
        OutOfScanners,
        InvalidScannerContext,
        InvalidPage,
    };
    pub const ReferenceSink = struct {
        pub fn visit(_: @This(), _: PageId) Error!void {}

        pub fn hasValueScanner(_: @This()) bool {
            return false;
        }

        pub fn visitValue(_: @This(), _: []const u8) Error!void {}
    };
    pub const ValueScanner = *const fn (
        context: ?*const anyopaque,
        value: []const u8,
        sink: ReferenceSink,
    ) Error!void;
    pub const Scanner = *const fn (
        context: ?*const anyopaque,
        page_id: PageId,
        page: []const u8,
        sink: ReferenceSink,
    ) Error!void;
    pub const ScannerEntry = struct {
        page_kind: u16,
        version: ScannerVersion,
        value_scan: ?ValueScanner,
    };

    scanners: [10]ScannerEntry = undefined,
    scanner_count: usize = 0,

    pub fn registerForCycle(
        self: *Self,
        page_kind: u16,
        version: ScannerVersion,
        _: ?*const anyopaque,
        _: Scanner,
        value_scan: ?ValueScanner,
    ) Error!void {
        if (self.scanner_count == self.scanners.len) {
            return error.OutOfScanners;
        }
        self.scanners[self.scanner_count] = .{
            .page_kind = page_kind,
            .version = version,
            .value_scan = value_scan,
        };
        self.scanner_count += 1;
    }
};

fn compare(_: void, left: []const u8, right: []const u8) std.math.Order {
    return std.mem.order(u8, left, right);
}

test "fullaz-db: built-in binding GC capabilities collect roots and register structural scanners" {
    const BptBinding = fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 32,
        .maximum_value_size = 32,
    }).Trait.Binding(Backend);
    const RtreeBinding = fullaz_db.rtree(.{
        .Coord = i32,
        .dimensions = 2,
        .maximum_entries = 4,
        .maximum_value_size = 16,
    }).Trait.Binding(Backend);
    const ChainBinding = fullaz_db.chainStore(.{}).Trait.Binding(Backend);
    const SequenceBinding = fullaz_db.weightedSequence(.{
        .maximum_chunk_size = 16,
    }).Trait.Binding(Backend);
    const SlotHeapBinding = fullaz_db.slotHeap(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 2,
        .maximum_key_size = 16,
        .maximum_value_size = 16,
    }).Trait.Binding(Backend);

    comptime fullaz_db.assertGc(BptBinding, TestCollector);
    comptime fullaz_db.assertGc(RtreeBinding, TestCollector);
    comptime fullaz_db.assertGc(ChainBinding, TestCollector);
    comptime fullaz_db.assertGc(SequenceBinding, TestCollector);
    comptime fullaz_db.assertGc(SlotHeapBinding, TestCollector);

    var device = try Device.init(std.testing.allocator, 512);
    defer device.deinit();
    var raw_cache = try RawCache.init(&device, std.testing.allocator, 16);
    defer raw_cache.deinit();
    var cache = Cache.init(std.testing.allocator, &raw_cache);
    defer cache.deinit();
    var backend = Backend{
        .allocator_value = std.testing.allocator,
        .cache_ptr = &cache,
    };

    var bpt_runtime: BptBinding.Runtime = undefined;
    try BptBinding.initRuntime(&bpt_runtime, &backend, .{ .base = 0x0100, .count = 2 }, .{});
    defer BptBinding.deinitRuntime(&bpt_runtime);
    bpt_runtime.state.root.set(10);

    var rtree_runtime: RtreeBinding.Runtime = undefined;
    try RtreeBinding.initRuntime(&rtree_runtime, &backend, .{ .base = 0x0102, .count = 2 }, .{});
    defer RtreeBinding.deinitRuntime(&rtree_runtime);
    rtree_runtime.state.root.set(20);

    var chain_runtime: ChainBinding.Runtime = undefined;
    try ChainBinding.initRuntime(&chain_runtime, &backend, .{ .base = 0x0104, .count = 1 }, .{});
    defer ChainBinding.deinitRuntime(&chain_runtime);
    chain_runtime.state.first.set(30);
    chain_runtime.state.last.set(31);
    chain_runtime.state.total_size.set(100);

    var sequence_runtime: SequenceBinding.Runtime = undefined;
    try SequenceBinding.initRuntime(&sequence_runtime, &backend, .{ .base = 0x0105, .count = 2 }, .{});
    defer SequenceBinding.deinitRuntime(&sequence_runtime);
    sequence_runtime.state.root.set(40);

    var slot_heap_runtime: SlotHeapBinding.Runtime = undefined;
    try SlotHeapBinding.initRuntime(&slot_heap_runtime, &backend, .{ .base = 0x0107, .count = 3 }, .{});
    defer SlotHeapBinding.deinitRuntime(&slot_heap_runtime);
    slot_heap_runtime.state.root.set(50);
    slot_heap_runtime.state.cached_top_page.set(53);
    slot_heap_runtime.state.cached_top_slot.set(0);
    slot_heap_runtime.state.available_inode_heads[1].set(54);
    slot_heap_runtime.state.fsm_class_roots[0].set(51);
    slot_heap_runtime.state.fsm_class_roots[1].set(52);

    var roots: std.ArrayList(u32) = .empty;
    defer roots.deinit(std.testing.allocator);
    try BptBinding.Gc(TestCollector).appendRoots(&bpt_runtime, std.testing.allocator, &roots);
    try RtreeBinding.Gc(TestCollector).appendRoots(&rtree_runtime, std.testing.allocator, &roots);
    try ChainBinding.Gc(TestCollector).appendRoots(&chain_runtime, std.testing.allocator, &roots);
    try SequenceBinding.Gc(TestCollector).appendRoots(&sequence_runtime, std.testing.allocator, &roots);
    try SlotHeapBinding.Gc(TestCollector).appendRoots(&slot_heap_runtime, std.testing.allocator, &roots);
    try std.testing.expectEqualSlices(u32, &.{ 10, 20, 30, 40, 50, 51, 52 }, roots.items);

    var collector = TestCollector{};
    try BptBinding.Gc(TestCollector).registerScanners(&bpt_runtime, &collector);
    try RtreeBinding.Gc(TestCollector).registerScanners(&rtree_runtime, &collector);
    try ChainBinding.Gc(TestCollector).registerScanners(&chain_runtime, &collector);
    try SequenceBinding.Gc(TestCollector).registerScanners(&sequence_runtime, &collector);
    try SlotHeapBinding.Gc(TestCollector).registerScanners(&slot_heap_runtime, &collector);

    try std.testing.expectEqual(@as(usize, 10), collector.scanner_count);
    try std.testing.expectEqualSlices(
        u16,
        &.{ 0x0100, 0x0101, 0x0102, 0x0103, 0x0104, 0x0105, 0x0106, 0x0107, 0x0108, 0x0109 },
        &.{
            collector.scanners[0].page_kind,
            collector.scanners[1].page_kind,
            collector.scanners[2].page_kind,
            collector.scanners[3].page_kind,
            collector.scanners[4].page_kind,
            collector.scanners[5].page_kind,
            collector.scanners[6].page_kind,
            collector.scanners[7].page_kind,
            collector.scanners[8].page_kind,
            collector.scanners[9].page_kind,
        },
    );
    for (collector.scanners) |scanner| {
        try std.testing.expectEqual(@as(TestCollector.ScannerVersion, 1), scanner.version);
        try std.testing.expect(scanner.value_scan == null);
    }
}
