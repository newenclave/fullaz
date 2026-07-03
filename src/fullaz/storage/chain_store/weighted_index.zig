const std = @import("std");
const errors = @import("../../core/errors.zig");
const PackedInt = @import("../../core/packed_int.zig").PackedInt;
const wbpt = @import("../../weighted_bpt/weighted_bpt.zig");

pub fn IndexEntry(comptime PageIdT: type, comptime SizeT: type, comptime Endian: std.builtin.Endian) type {
    return extern struct {
        const PageId = PackedInt(PageIdT, Endian);
        const Size = PackedInt(SizeT, Endian);
        page_id: PageId,
        size: Size,
    };
}

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

pub fn Located(comptime Pid: type, comptime Size: type) type {
    return struct {
        page_id: Pid,
        chunk_start: Size,
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
    comptime PageCacheType: type,
    comptime StorageManager: type,
    comptime Endian: std.builtin.Endian,
) type {
    const BlockDevice = PageCacheType.UnderlyingDevice;
    const BlockIdType = BlockDevice.BlockId;
    const SizeT = StorageManager.Size;

    const EntrySizeT = SizeT;
    const Policy = IndexValuePolicy(BlockIdType, EntrySizeT, Endian);
    const Entry = IndexEntry(BlockIdType, EntrySizeT, Endian);

    const IdxMgr = struct {
        const Self = @This();
        pub const Error = StorageManager.Error;
        pub const PageId = BlockIdType;

        sm: *StorageManager,

        pub fn getRoot(self: *const Self) ?PageId {
            return self.sm.getIndexRoot();
        }
        pub fn setRoot(self: *Self, root: ?PageId) Error!void {
            return self.sm.setIndexRoot(root);
        }
        pub fn destroyPage(self: *Self, id: PageId) Error!void {
            return self.sm.destroyPage(id);
        }
    };

    const Model = wbpt.models.paged.PagedModel(PageCacheType, IdxMgr, SizeT, Policy);
    const Tree = wbpt.WeightedBpt(Model);

    return struct {
        const Self = @This();

        pub const requires_root = true;
        pub const PageId = BlockIdType;
        pub const Size = SizeT;
        pub const LocatedRes = Located(BlockIdType, SizeT);
        // Mirror Tree.Error (private): model errors ∪ the wbpt algorithm's own.
        pub const Error = Model.Error || errors.IteratorError || errors.BptError;

        cache: *PageCacheType,
        sm: *StorageManager,

        pub fn init(cache: *PageCacheType, mgr: *StorageManager, settings: anytype) Self {
            _ = settings;
            return .{ .cache = cache, .sm = mgr };
        }

        pub fn deinit(_: *Self) void {}

        pub fn locate(self: *const Self, offset: Size) Error!?LocatedRes {
            var idx_mgr = IdxMgr{ .sm = self.sm };
            var model = Model.init(self.cache, &idx_mgr, .{});
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
            const last = (try self.sm.getLast()) orelse return null;
            return LocatedRes{ .page_id = last, .chunk_start = sealed_total };
        }

        pub fn onSeal(self: *Self, page_id: PageId, size: Size) Error!void {
            var idx_mgr = IdxMgr{ .sm = self.sm };
            var model = Model.init(self.cache, &idx_mgr, .{});
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
            var idx_mgr = IdxMgr{ .sm = self.sm };
            var model = Model.init(self.cache, &idx_mgr, .{});
            var tree = Tree.init(&model, .neighbor_share);
            defer tree.deinit();

            const total = try tree.totalWeight();
            if (total == 0) return;
            try tree.removeEntry(total - 1);
        }

        pub fn clear(self: *Self) Error!void {
            var idx_mgr = IdxMgr{ .sm = self.sm };
            var model = Model.init(self.cache, &idx_mgr, .{});
            var tree = Tree.init(&model, .neighbor_share);
            defer tree.deinit();
            while (try tree.totalWeight() > 0) {
                try tree.removeEntry(0);
            }
        }
    };
}
