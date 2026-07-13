const std = @import("std");
const rtree_view = @import("view.zig");
const interfaces = @import("../interfaces.zig");
const geometry = @import("../../geometry.zig");
const errors = @import("../../../core/errors.zig");

pub const Settings = struct {
    leaf_page_kind: u16 = 0,
    inode_page_kind: u16 = 1,
};

pub fn PagedModel(
    comptime PageCacheType: type,
    comptime StorageManager: type,
    comptime CoordT: type,
    comptime dims: usize,
    comptime max_entries_v: usize,
    comptime max_value_size: usize,
    comptime Endian: std.builtin.Endian,
) type {
    comptime {
        interfaces.requiresStorageManager(StorageManager);
        interfaces.requiresPageCache(PageCacheType);
        if (max_entries_v < 4) {
            @compileError("max_entries must be at least 4");
        }
    }

    const BlockDevice = PageCacheType.UnderlyingDevice;
    const PageHandle = PageCacheType.Handle;
    const BlockIdType = BlockDevice.BlockId;

    const RtreeView = rtree_view.View(BlockIdType, u16, CoordT, dims, Endian, false);
    const RtreeViewConst = rtree_view.View(BlockIdType, u16, CoordT, dims, Endian, true);

    const Key = geometry.BoundingBox(CoordT, dims);
    const ValueType = []const u8;

    const ValueBuf = struct {
        len: usize = 0,
        data: [max_value_size]u8 = undefined,
    };

    const Context = struct {
        cache: *PageCacheType,
        storage_mgr: *StorageManager,
        settings: Settings,
    };

    const ErrorSet = errors.PageError ||
        errors.SlotsError ||
        PageCacheType.Error ||
        error{ ValueTooLarge, NodeFull };

    const idOrNull = struct {
        fn call(id: BlockIdType) ?BlockIdType {
            return if (id == std.math.maxInt(BlockIdType)) null else id;
        }
    }.call;

    const LeafImpl = struct {
        const Self = @This();
        const MutView = RtreeView.LeafSubheaderView;
        const ConstView = RtreeViewConst.LeafSubheaderView;

        pub const Error = ErrorSet;

        handle: PageHandle = undefined,
        self_id: BlockIdType = undefined,
        ctx: *Context = undefined,

        fn init(ph: PageHandle, self_id: BlockIdType, ctx: *Context) Self {
            return .{ .handle = ph, .self_id = self_id, .ctx = ctx };
        }

        pub fn deinit(self: *Self) void {
            self.handle.deinit();
        }

        pub fn take(self: *Self) Error!Self {
            return Self{
                .handle = try self.handle.take(),
                .self_id = self.self_id,
                .ctx = self.ctx,
            };
        }

        pub fn id(self: *const Self) BlockIdType {
            return self.self_id;
        }

        pub fn size(self: *const Self) Error!usize {
            const view = ConstView.init(try self.handle.getData());
            return try view.entries();
        }

        pub fn capacity(_: *const Self) Error!usize {
            return max_entries_v;
        }

        pub fn getMbr(self: *const Self, pos: usize) Error!Key {
            const view = ConstView.init(try self.handle.getData());
            return try view.getMbr(pos);
        }

        pub fn nodeMbr(self: *const Self) Error!Key {
            const view = ConstView.init(try self.handle.getData());
            return try view.nodeMbr();
        }

        pub fn getValue(self: *const Self, pos: usize) Error!ValueType {
            const view = ConstView.init(try self.handle.getData());
            return try view.getValue(pos);
        }

        pub fn erase(self: *Self, pos: usize) Error!void {
            var view = MutView.init(try self.handle.getDataMut());
            return view.erase(pos);
        }

        pub fn compact(self: *Self) Error!void {
            var view = MutView.init(try self.handle.getDataMut());
            var ph = self.ctx.cache.getTemporaryPage() catch {
                try view.compactInPlace();
                return;
            };
            defer ph.deinit();
            const data = ph.getDataMut() catch {
                try view.compactInPlace();
                return;
            };
            try view.compact(data);
        }

        pub fn clear(self: *Self) Error!void {
            var view = MutView.init(try self.handle.getDataMut());
            return view.clear();
        }

        pub fn getParent(self: *const Self) Error!?BlockIdType {
            const view = ConstView.init(try self.handle.getData());
            return idOrNull(view.subheader().parent.get());
        }

        pub fn setParent(self: *Self, parent: ?BlockIdType) Error!void {
            var view = MutView.init(try self.handle.getDataMut());
            if (parent) |pid| {
                view.subheaderMut().parent.set(pid);
            } else {
                view.subheaderMut().parent.setMax();
            }
        }

        pub fn canInsertEntry(self: *const Self, _: Key, value: ValueType) Error!bool {
            if (value.len > max_value_size) return Error.ValueTooLarge;
            const view = ConstView.init(try self.handle.getData());
            if ((try view.entries()) >= max_entries_v) {
                return false;
            }
            return (try view.canAppend(value.len)) != .not_enough;
        }

        pub fn insertEntry(self: *Self, mbr: Key, value: ValueType) Error!void {
            if (value.len > max_value_size) {
                return Error.ValueTooLarge;
            }
            const status = blk: {
                const view = ConstView.init(try self.handle.getData());
                break :blk try view.canAppend(value.len);
            };
            if (status == .not_enough) return Error.NodeFull;
            if (status == .need_compact) {
                var tmp = try self.ctx.cache.getTemporaryPage();
                defer tmp.deinit();
                var view = MutView.init(try self.handle.getDataMut());
                try view.compact(try tmp.getDataMut());
            }
            var view = MutView.init(try self.handle.getDataMut());
            try view.append(mbr, value);
        }
    };

    const InodeImpl = struct {
        const Self = @This();
        const MutView = RtreeView.InodeSubheaderView;
        const ConstView = RtreeViewConst.InodeSubheaderView;

        pub const Error = ErrorSet;

        handle: PageHandle = undefined,
        self_id: BlockIdType = undefined,
        ctx: *Context = undefined,

        fn init(ph: PageHandle, self_id: BlockIdType, ctx: *Context) Self {
            return .{ .handle = ph, .self_id = self_id, .ctx = ctx };
        }

        pub fn deinit(self: *Self) void {
            self.handle.deinit();
        }

        pub fn take(self: *Self) Error!Self {
            return Self{
                .handle = try self.handle.take(),
                .self_id = self.self_id,
                .ctx = self.ctx,
            };
        }

        pub fn id(self: *const Self) BlockIdType {
            return self.self_id;
        }

        pub fn size(self: *const Self) Error!usize {
            const view = ConstView.init(try self.handle.getData());
            return try view.entries();
        }

        pub fn capacity(_: *const Self) Error!usize {
            return max_entries_v;
        }

        pub fn getMbr(self: *const Self, pos: usize) Error!Key {
            const view = ConstView.init(try self.handle.getData());
            return try view.getMbr(pos);
        }

        pub fn nodeMbr(self: *const Self) Error!Key {
            const view = ConstView.init(try self.handle.getData());
            return try view.nodeMbr();
        }

        pub fn erase(self: *Self, pos: usize) Error!void {
            var view = MutView.init(try self.handle.getDataMut());
            return view.erase(pos);
        }

        pub fn compact(self: *Self) Error!void {
            var view = MutView.init(try self.handle.getDataMut());
            var ph = self.ctx.cache.getTemporaryPage() catch {
                try view.compactInPlace();
                return;
            };
            defer ph.deinit();
            const data = ph.getDataMut() catch {
                try view.compactInPlace();
                return;
            };
            try view.compact(data);
        }

        pub fn clear(self: *Self) Error!void {
            var view = MutView.init(try self.handle.getDataMut());
            return view.clear();
        }

        pub fn getParent(self: *const Self) Error!?BlockIdType {
            const view = ConstView.init(try self.handle.getData());
            return idOrNull(view.subheader().parent.get());
        }

        pub fn setParent(self: *Self, parent: ?BlockIdType) Error!void {
            var view = MutView.init(try self.handle.getDataMut());
            if (parent) |pid| {
                view.subheaderMut().parent.set(pid);
            } else {
                view.subheaderMut().parent.setMax();
            }
        }

        pub fn getLevel(self: *const Self) Error!usize {
            const view = ConstView.init(try self.handle.getData());
            return view.getLevel();
        }

        pub fn setLevel(self: *Self, level: usize) Error!void {
            var view = MutView.init(try self.handle.getDataMut());
            view.setLevel(level);
        }

        pub fn getChild(self: *const Self, pos: usize) Error!BlockIdType {
            const view = ConstView.init(try self.handle.getData());
            return try view.getChild(pos);
        }

        pub fn canInsertChild(self: *const Self, _: Key, _: BlockIdType) Error!bool {
            const view = ConstView.init(try self.handle.getData());
            if ((try view.entries()) >= max_entries_v) return false;
            return (try view.canAppend()) != .not_enough;
        }

        pub fn insertChild(self: *Self, mbr: Key, child: BlockIdType) Error!void {
            const status = blk: {
                const view = ConstView.init(try self.handle.getData());
                break :blk try view.canAppend();
            };
            if (status == .not_enough) return Error.NodeFull;
            if (status == .need_compact) {
                var tmp = try self.ctx.cache.getTemporaryPage();
                defer tmp.deinit();
                var view = MutView.init(try self.handle.getDataMut());
                try view.compact(try tmp.getDataMut());
            }
            var view = MutView.init(try self.handle.getDataMut());
            try view.append(mbr, child);
        }

        pub fn updateChildMbr(self: *Self, pos: usize, mbr: Key) Error!void {
            var view = MutView.init(try self.handle.getDataMut());
            return view.updateChildMbr(pos, mbr);
        }
    };

    const AccessorImpl = struct {
        const Self = @This();
        pub const Error = ErrorSet;
        pub const PageCache = PageCacheType;

        ctx: Context,

        fn init(ctx: Context) Self {
            return .{ .ctx = ctx };
        }

        pub fn deinit(_: *Self) void {}

        pub fn getRoot(self: *const Self) ?BlockIdType {
            return self.ctx.storage_mgr.getRoot();
        }

        pub fn setRoot(self: *Self, new_root: ?BlockIdType) Error!void {
            return self.ctx.storage_mgr.setRoot(new_root);
        }

        pub fn destroy(self: *Self, id: BlockIdType) Error!void {
            return self.ctx.storage_mgr.destroyPage(id);
        }

        pub fn createLeaf(self: *Self) Error!LeafImpl {
            var ph = try self.ctx.cache.create();
            defer ph.deinit();
            const pid = try ph.pid();
            var view = LeafImpl.MutView.init(try ph.getDataMut());
            try view.formatPage(self.ctx.settings.leaf_page_kind, pid, 0);
            return LeafImpl.init(try ph.take(), pid, &self.ctx);
        }

        pub fn createInode(self: *Self) Error!InodeImpl {
            var ph = try self.ctx.cache.create();
            defer ph.deinit();
            const pid = try ph.pid();
            var view = InodeImpl.MutView.init(try ph.getDataMut());
            try view.formatPage(self.ctx.settings.inode_page_kind, pid, 0);
            return InodeImpl.init(try ph.take(), pid, &self.ctx);
        }

        pub fn loadLeaf(self: *Self, id_opt: ?BlockIdType) Error!?LeafImpl {
            const id = id_opt orelse return null;
            var ph = try self.ctx.cache.fetch(id);
            errdefer ph.deinit();
            const view = LeafImpl.ConstView.init(try ph.getData());
            if (view.page_view.header().kind.get() != self.ctx.settings.leaf_page_kind) {
                ph.deinit();
                return null;
            }
            return LeafImpl.init(ph, id, &self.ctx);
        }

        pub fn loadInode(self: *Self, id_opt: ?BlockIdType) Error!?InodeImpl {
            const id = id_opt orelse return null;
            var ph = try self.ctx.cache.fetch(id);
            errdefer ph.deinit();
            const view = InodeImpl.ConstView.init(try ph.getData());
            if (view.page_view.header().kind.get() != self.ctx.settings.inode_page_kind) {
                ph.deinit();
                return null;
            }
            return InodeImpl.init(ph, id, &self.ctx);
        }

        pub fn isLeafId(self: *Self, id: BlockIdType) Error!bool {
            var ph = try self.ctx.cache.fetch(id);
            defer ph.deinit();
            const view = LeafImpl.ConstView.init(try ph.getData());
            return view.page_view.header().kind.get() == self.ctx.settings.leaf_page_kind;
        }

        pub fn deinitLeaf(_: *Self, leaf: ?LeafImpl) void {
            if (leaf) |l| {
                var v = l;
                v.deinit();
            }
        }

        pub fn deinitInode(_: *Self, inode: ?InodeImpl) void {
            if (inode) |n| {
                var v = n;
                v.deinit();
            }
        }
    };

    return struct {
        const Self = @This();

        pub const NodeIdType = BlockIdType;
        pub const Error = ErrorSet;
        pub const KeyType = Key;
        pub const ValueInType = ValueType;
        pub const ValueOutType = ValueType;
        pub const ValueBufType = ValueBuf;
        pub const LeafType = LeafImpl;
        pub const InodeType = InodeImpl;
        pub const AccessorType = AccessorImpl;
        pub const BlockDeviceType = BlockDevice;
        pub const max_entries = max_entries_v;

        accessor: AccessorImpl,

        pub fn init(cache: *PageCacheType, storage_mgr: *StorageManager, settings: Settings) Self {
            return .{
                .accessor = AccessorImpl.init(.{
                    .cache = cache,
                    .storage_mgr = storage_mgr,
                    .settings = settings,
                }),
            };
        }

        pub fn deinit(_: *Self) void {}

        pub fn getAccessor(self: *Self) *AccessorImpl {
            return &self.accessor;
        }

        pub fn valueOutAsIn(_: *const Self, value: ValueOutType) ValueInType {
            return value;
        }

        pub fn copyValueOut(_: *const Self, value: ValueOutType) ValueBufType {
            var buf: ValueBufType = .{ .len = value.len };
            @memcpy(buf.data[0..value.len], value);
            return buf;
        }

        pub fn valueBufAsIn(_: *const Self, buf: *const ValueBufType) ValueInType {
            return buf.data[0..buf.len];
        }

        pub fn isValidId(_: *const Self, id: ?NodeIdType) bool {
            const pid = id orelse return false;
            return pid != std.math.maxInt(NodeIdType);
        }

        // TODO: needs to be calculated?
        pub fn maxEntries(_: *const Self) usize {
            return max_entries_v;
        }
    };
}
