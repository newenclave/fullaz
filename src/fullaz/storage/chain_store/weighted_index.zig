const std = @import("std");
const errors = @import("../../core/errors.zig");
const storage_manager = @import("../../core/storage_manager.zig");
const wbpt = @import("../../weighted_bpt/weighted_bpt.zig");
const index_entry = @import("index_entry.zig");
const chain_state = @import("state.zig");

pub const scanLeafRefs = @import("weighted_scanner.zig").scanLeafRefs;
pub const scanInodeRefs = @import("weighted_scanner.zig").scanInodeRefs;

pub const IndexEntry = index_entry.IndexEntry;

pub fn IndexValuePolicy(comptime PageIdT: type, comptime SizeT: type, comptime Endian: std.builtin.Endian) type {
    return struct {
        const Entry = IndexEntry(PageIdT, SizeT, Endian);

        const Self = @This();

        pub const Error = errors.PageError;

        val: []const u8,

        pub fn init(ctx: anytype, val: []const u8) Self {
            _ = ctx;
            return .{ .val = val };
        }

        pub fn deinit(_: *Self) void {}

        pub fn weight(self: *const Self) Error!SizeT {
            const entry: *const Entry = @ptrCast(self.val.ptr);
            return @as(SizeT, entry.size.get());
        }

        pub fn get(self: *const Self) Error![]const u8 {
            return self.val;
        }

        pub fn splitOfRight(_: *Self, _: SizeT) Error!Self {
            return Error.BadData;
        }

        pub fn splitOfLeft(_: *Self, _: SizeT) Error!Self {
            return Error.BadData;
        }

        pub fn expectedSplitDataFormat(_: *const Self, _: []const u8, pos: usize) struct { left: usize, right: usize } {
            return .{
                .left = pos,
                .right = pos,
            };
        }
    };
}

pub fn Located(comptime PidT: type, comptime SizeT: type) type {
    return struct {
        page_id: PidT,
        chunk_start: SizeT,
    };
}

pub fn NoIndex(comptime PageIdT: type, comptime SizeT: type) type {
    return struct {
        const Self = @This();
        pub const PageId = PageIdT;
        pub const Size = SizeT;
        pub const LocatedRes = Located(PageId, Size);
        pub const Error = error{};

        pub fn init(cache: anytype, mgr: anytype, settings: anytype) Self {
            _ = cache;
            _ = mgr;
            _ = settings;
            return .{};
        }
        pub fn deinit(_: *Self) void {}

        pub fn locate(_: *const Self, offset: Size) Error!?LocatedRes {
            _ = offset;
            return null;
        }

        pub fn onSeal(_: *Self, page_id: PageId, size: Size) Error!void {
            _ = page_id;
            _ = size;
        }
        pub fn onUnseal(_: *Self) Error!void {}
        pub fn clear(_: *Self) Error!void {}
    };
}

pub fn WeightedIndex(
    comptime PageCacheT: type,
    comptime StorageManagerT: type,
    comptime Endian: std.builtin.Endian,
) type {
    const CachePageId = PageCacheT.Pid;
    const SizeT = StorageManagerT.Size;

    const EntrySizeT = SizeT;
    const Policy = IndexValuePolicy(CachePageId, EntrySizeT, Endian);
    const Entry = IndexEntry(CachePageId, EntrySizeT, Endian);
    const WeightedStateT = chain_state.WeightedState(CachePageId, SizeT, Endian);
    const ChainStateT = chain_state.State(CachePageId, SizeT, Endian);
    const ChainStateManager = storage_manager.PagedFieldStorageManager(
        StorageManagerT,
        WeightedStateT,
        "chain",
    );
    const IndexStateManager = storage_manager.PagedFieldStorageManager(
        StorageManagerT,
        WeightedStateT,
        "index",
    );
    const ChainStateView = storage_manager.StateAccessor(
        ChainStateManager.StateLeaseType,
        ChainStateT,
    );
    const Model = wbpt.models.paged.PagedModel(
        PageCacheT,
        IndexStateManager,
        SizeT,
        Policy,
    );
    const ModelSettings = wbpt.models.paged.Settings;
    const Tree = wbpt.WeightedBpt(Model);

    return struct {
        const Self = @This();

        pub const requires_root = true;
        pub const PageId = CachePageId;
        pub const Size = SizeT;
        pub const LocatedRes = Located(CachePageId, SizeT);
        // Mirror Tree.Error (private): model errors ∪ the wbpt algorithm's own.
        pub const Error = Model.Error || errors.IteratorError || errors.BptError;

        cache: *PageCacheT,
        sm: *StorageManagerT,
        settings: ModelSettings,

        pub fn init(cache: *PageCacheT, mgr: *StorageManagerT, settings: anytype) Self {
            var model_settings: ModelSettings = .{};
            if (@hasField(@TypeOf(settings), "index_leaf_page_kind")) {
                model_settings.leaf_page_kind = settings.index_leaf_page_kind;
            }
            if (@hasField(@TypeOf(settings), "index_inode_page_kind")) {
                model_settings.inode_page_kind = settings.index_inode_page_kind;
            }
            return .{ .cache = cache, .sm = mgr, .settings = model_settings };
        }

        pub fn deinit(_: *Self) void {}

        pub fn locate(self: *const Self, offset: Size) Error!?LocatedRes {
            var idx_mgr = IndexStateManager.init(self.sm);
            var model = Model.init(self.cache, &idx_mgr, self.settings);
            var tree = Tree.init(&model, .neighbor_share);
            defer tree.deinit();

            const sealed_total: Size = @intCast(try tree.totalWeight());
            if (offset < sealed_total) {
                var buf: [@sizeOf(Entry)]u8 = undefined;
                const found = (try tree.findByWeight(@intCast(offset), &buf)) orelse return null;
                const entry: *const Entry = @ptrCast(&buf);
                return LocatedRes{
                    .page_id = entry.page_id.get(),
                    .chunk_start = offset - @as(Size, @intCast(found.intra_weight)),
                };
            }
            // Active tail chunk: not in the tree; it starts at the sealed total.
            const tail_page_id = (try self.getLast()) orelse return null;
            return LocatedRes{ .page_id = tail_page_id, .chunk_start = sealed_total };
        }

        pub fn onSeal(self: *Self, page_id: PageId, size: Size) Error!void {
            var idx_mgr = IndexStateManager.init(self.sm);
            var model = Model.init(self.cache, &idx_mgr, self.settings);
            var tree = Tree.init(&model, .neighbor_share);
            defer tree.deinit();

            const where = try tree.totalWeight();
            var buf: [@sizeOf(Entry)]u8 = undefined;
            const entry: *Entry = @ptrCast(&buf);
            entry.page_id.set(page_id);
            entry.size.set(@intCast(size));
            _ = try tree.insert(where, &buf);
        }

        pub fn onUnseal(self: *Self) Error!void {
            var idx_mgr = IndexStateManager.init(self.sm);
            var model = Model.init(self.cache, &idx_mgr, self.settings);
            var tree = Tree.init(&model, .neighbor_share);
            defer tree.deinit();

            const total = try tree.totalWeight();
            if (total == 0) return;
            try tree.removeEntry(total - 1);
        }

        pub fn clear(self: *Self) Error!void {
            var idx_mgr = IndexStateManager.init(self.sm);
            var model = Model.init(self.cache, &idx_mgr, self.settings);
            var tree = Tree.init(&model, .neighbor_share);
            defer tree.deinit();
            while (try tree.totalWeight() > 0) {
                try tree.removeEntry(0);
            }
        }

        fn getLast(self: *const Self) Error!?PageId {
            var chain_manager = ChainStateManager.init(self.sm);
            var lease = try chain_manager.state();
            defer lease.deinit();
            const state = try ChainStateView.view(&lease);
            const page_id = state.last.get();
            return if (page_id == std.math.maxInt(PageId)) null else page_id;
        }
    };
}
