const std = @import("std");
const device_interface = @import("../../device/interfaces.zig");
const page_cache = @import("../../page_cache.zig");
const bpt_page = @import("../../page/bpt.zig");
const interfaces = @import("interfaces.zig");
const errors = @import("../../errors.zig");

pub const Settings = struct {
    maximum_key_size: usize = 128,
    maximum_value_size: usize = 128,
    leaf_page_kind: u16 = 0,
    inode_page_kind: u16 = 1,
};

pub fn PagedModel(comptime PageCacheType: type, comptime StorageManager: type, comptime cmp: anytype, comptime Ctx: type) type {
    interfaces.requireStorageManager(StorageManager);

    const BlockDevice = PageCacheType.UnderlyingDevice;
    const PageHandle = PageCacheType.Handle;
    const BlockIdType = BlockDevice.BlockId;

    const BptPage = bpt_page.Bpt(BlockIdType, u16, .little, false);
    const BptPageConst = bpt_page.Bpt(BlockIdType, u16, .little, true);

    const KeyType = []const u8;
    const ValueType = []const u8;

    const Context = struct {
        cache: *PageCacheType = undefined,
        storage_mgr: *StorageManager = undefined,
        cts: Ctx = undefined,
        settings: Settings = undefined,
    };

    const ErrorSet = errors.PageError ||
        errors.SlotsError ||
        PageCacheType.Error ||
        errors.OrderError ||
        errors.BptError;

    const LeafImpl = struct {
        const Self = @This();
        const PageViewType = BptPage.LeafSubheaderView;
        const PageViewTypeConst = BptPageConst.LeafSubheaderView;
        handle: PageHandle = undefined,
        self_id: BlockIdType = undefined,
        ctx: *Context = undefined,

        pub const Error = ErrorSet;

        fn init(ph: PageHandle, self_id: BlockIdType, ctx: *Context) Self {
            return .{
                .handle = ph,
                .self_id = self_id,
                .ctx = ctx,
            };
        }

        pub fn deinit(self: *Self) void {
            self.handle.deinit();
        }

        pub fn take(self: *Self) !Self {
            return Self{
                .handle = try self.handle.take(),
                .self_id = self.self_id,
                .ctx = self.ctx,
            };
        }

        pub fn size(self: *const Self) Error!usize {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return try view.entries();
        }

        pub fn capacity(self: *const Self) Error!usize {
            const view = PageViewTypeConst.init(try self.handle.getData());
            const maximum_slot_size = self.ctx.settings.maximum_key_size + self.ctx.settings.maximum_value_size;
            return try view.capacityFor(maximum_slot_size);
        }

        pub fn isUnderflowed(self: *const Self) Error!bool {
            return (try self.size()) < (try self.capacity() + 1) / 2;
        }

        pub fn keysEqual(self: *const Self, k1: KeyType, k2: KeyType) bool {
            const CmpReturnType = @TypeOf(cmp(self.ctx, k1, k2));
            const is_error_union = @typeInfo(CmpReturnType) == .error_union;

            const order = blk: {
                if (comptime is_error_union) {
                    break :blk cmp(self.ctx, k1, k2) catch return false;
                } else {
                    break :blk cmp(self.ctx, k1, k2);
                }
            };
            return order == .eq;
        }

        pub fn keyPosition(self: *const Self, key: KeyType) Error!usize {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return try view.lowerBoundWith(key, cmp, self.ctx);
        }

        pub fn getKey(self: *const Self, pos: usize) Error!KeyType {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return (try view.get(pos)).key;
        }

        pub fn getValue(self: *const Self, pos: usize) Error!ValueType {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return (try view.get(pos)).value;
        }

        pub fn getNext(self: *const Self) ?BlockIdType {
            const data = self.handle.getData() catch return null;
            const view = PageViewTypeConst.init(data);
            const current = view.subheader().next.get();
            if (current != std.math.maxInt(BlockIdType)) {
                return current;
            }
            return null;
        }

        pub fn getPrev(self: *const Self) ?BlockIdType {
            const data = self.handle.getData() catch return null;
            const view = PageViewTypeConst.init(data);
            const current = view.subheader().prev.get();
            if (current != std.math.maxInt(BlockIdType)) {
                return current;
            }
            return null;
        }

        pub fn setNext(self: *Self, next_id: ?BlockIdType) Error!void {
            var view = PageViewType.init(try self.handle.getDataMut());
            if (next_id) |nid| {
                view.subheaderMut().next.set(nid);
            } else {
                view.subheaderMut().next.set(std.math.maxInt(BlockIdType));
            }
        }

        pub fn setPrev(self: *Self, prev_id: ?BlockIdType) Error!void {
            var view = PageViewType.init(try self.handle.getDataMut());
            if (prev_id) |pid| {
                view.subheaderMut().prev.set(pid);
            } else {
                view.subheaderMut().prev.set(std.math.maxInt(BlockIdType));
            }
        }

        pub fn setParent(self: *Self, parent_id: ?BlockIdType) Error!void {
            var view = PageViewType.init(try self.handle.getDataMut());
            if (parent_id) |pid| {
                view.subheaderMut().parent.set(pid);
            } else {
                view.subheaderMut().parent.set(std.math.maxInt(BlockIdType));
            }
        }

        pub fn getParent(self: *const Self) ?BlockIdType {
            const data = self.handle.getData() catch return null;
            const view = PageViewTypeConst.init(data);
            const parent = view.subheader().parent.get();
            if (parent != std.math.maxInt(BlockIdType)) {
                return parent;
            }
            return null;
        }

        pub fn id(self: *const Self) BlockIdType {
            return self.self_id;
        }

        fn checkKeyValue(self: *const Self, key: ?KeyType, value: ?ValueType) errors.BptError!void {
            if (key) |key_data| {
                if (key_data.len > self.ctx.settings.maximum_key_size) {
                    return Error.KeyTooLarge;
                }
            }
            if (value) |value_data| {
                if (value_data.len > self.ctx.settings.maximum_value_size) {
                    return Error.ValueTooLarge;
                }
            }
        }

        pub fn canInsertValue(self: *const Self, pos: usize, key: KeyType, value: ValueType) Error!bool {
            try self.checkKeyValue(key, value);
            const view = PageViewTypeConst.init(try self.handle.getData());
            return try view.canInsert(pos, key, value) != .not_enough;
        }

        pub fn insertValue(self: *Self, pos: usize, key: KeyType, value: ValueType) Error!void {
            try self.checkKeyValue(key, value);

            var tmp_page = try self.ctx.cache.getTemporaryPage();
            defer tmp_page.deinit();

            const view = PageViewTypeConst.init(try self.handle.getData());
            const res = try view.canInsert(pos, key, value);
            if (res == .not_enough) {
                return Error.NodeFull;
            } else if (res == .need_compact) {
                var view_mut = PageViewType.init(try self.handle.getDataMut());
                // TODO: check if possible to pass a buffer here to compact with the buffer
                var slots_dir = try view_mut.slotsDirMut();
                slots_dir.compactWithBuffer(try tmp_page.getDataMut()) catch {
                    try slots_dir.compactInPlace();
                };
            }
            var view_mut = PageViewType.init(try self.handle.getDataMut());
            try view_mut.insert(pos, key, value);
        }

        pub fn canUpdateValue(self: *const Self, pos: usize, key: KeyType, value: ValueType) Error!bool {
            try self.checkKeyValue(key, value);
            const view = PageViewTypeConst.init(try self.handle.getData());
            return try view.canUpdateValue(pos, key, value) != .not_enough;
        }

        pub const UpdateStatus = BptPageConst.SlotsAvailableStatus;

        pub fn canUpdateValueStatus(self: *const Self, pos: usize, key: KeyType, value: ValueType) Error!UpdateStatus {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return view.canUpdateValue(pos, key, value);
        }

        pub fn updateValue(self: *Self, pos: usize, value: ValueType) Error!void {
            try self.checkKeyValue(null, value);
            var tmp_page = try self.ctx.cache.getTemporaryPage();
            defer tmp_page.deinit();
            var view = PageViewType.init(try self.handle.getDataMut());
            return view.updateValue(pos, value, try tmp_page.getDataMut());
        }

        pub fn erase(self: *Self, pos: usize) Error!void {
            var view = PageViewType.init(try self.handle.getDataMut());
            var slots_dir = try view.slotsDirMut();
            return slots_dir.remove(pos);
        }
    };

    const InodeImpl = struct {
        const Self = @This();
        const PageViewType = BptPage.InodeSubheaderView;
        const PageViewTypeConst = BptPageConst.InodeSubheaderView;

        pub const Error = ErrorSet;

        handle: PageHandle = undefined,
        self_id: BlockIdType = undefined,
        ctx: *Context = undefined,

        fn init(ph: PageHandle, self_id: BlockIdType, ctx: *Context) Self {
            return .{
                .handle = ph,
                .self_id = self_id,
                .ctx = ctx,
            };
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

        pub fn size(self: *const Self) Error!usize {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return (try view.slotsDir()).size();
        }

        pub fn capacity(self: *const Self) Error!usize {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return try view.capacityFor(self.ctx.settings.maximum_key_size);
        }

        pub fn isUnderflowed(self: *const Self) Error!bool {
            return (try self.size()) < (try self.capacity() + 1) / 2;
        }

        pub fn keysEqual(self: *const Self, k1: KeyType, k2: KeyType) bool {
            const CmpReturnType = @TypeOf(cmp(self.ctx, k1, k2));
            const is_error_union = @typeInfo(CmpReturnType) == .error_union;

            const order = blk: {
                if (comptime is_error_union) {
                    break :blk cmp(self.ctx, k1, k2) catch return false;
                } else {
                    break :blk cmp(self.ctx, k1, k2);
                }
            };
            return order == .eq;
        }

        pub fn getKey(self: *const Self, pos: usize) Error!KeyType {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return (try view.get(pos)).key;
        }

        pub fn getChild(self: *const Self, pos: usize) Error!BlockIdType {
            const view = PageViewTypeConst.init(try self.handle.getData());
            const current_size = (try view.slotsDir()).size();
            if (pos < current_size) {
                return (try view.get(pos)).child;
            } else if (pos == current_size) {
                return view.subheader().rightmost_child.get();
            } else {
                return Error.OutOfBounds;
            }
        }

        pub fn id(self: *const Self) BlockIdType {
            return self.self_id;
        }

        pub fn keyPosition(self: *const Self, key: KeyType) Error!usize {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return try view.upperBoundWith(key, cmp, self.ctx);
        }

        pub fn canUpdateKey(self: *const Self, pos: usize, new_key: KeyType) Error!bool {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return try view.canUpdate(pos, new_key) != .not_enough;
        }

        // TODO: move it to page/bpt.zig?
        pub fn canInsertChild(self: *const Self, pos: usize, key: KeyType, cid: BlockIdType) Error!bool {
            if (key.len > self.ctx.settings.maximum_key_size) {
                return Error.KeyTooLarge;
            }

            const view = PageViewTypeConst.init(try self.handle.getData());
            return try view.canInsert(pos, key, cid) != .not_enough;
        }

        pub fn insertChild(self: *Self, pos: usize, key: KeyType, child_id: BlockIdType) Error!void {
            if (key.len > self.ctx.settings.maximum_key_size) {
                return Error.KeyTooLarge;
            }

            var tmp_page = try self.ctx.cache.getTemporaryPage();
            defer tmp_page.deinit();

            var view = PageViewTypeConst.init(try self.handle.getData());
            const current_available = try view.canInsert(pos, key, child_id);
            if (current_available == .not_enough) {
                return Error.NodeFull;
            } else if (current_available == .need_compact) {
                var view_mut = PageViewType.init(try self.handle.getDataMut());
                var slots_dir = try view_mut.slotsDirMut();
                slots_dir.compactWithBuffer(try tmp_page.getDataMut()) catch {
                    try slots_dir.compactInPlace();
                };
            }
            var view_mut = PageViewType.init(try self.handle.getDataMut());
            try view_mut.insert(pos, key, child_id);
        }

        pub fn updateChild(self: *Self, pos: usize, child_id: BlockIdType) Error!void {
            var view = PageViewType.init(try self.handle.getDataMut());
            const current_size = (try view.slotsDir()).size();
            if (pos < current_size) {
                try view.updateChild(pos, child_id);
            } else if (pos == current_size) {
                view.subheaderMut().rightmost_child.set(child_id);
            } else {
                return Error.OutOfBounds;
            }
        }

        pub fn updateKey(self: *Self, pos: usize, key: KeyType) Error!void {
            if (key.len > self.ctx.settings.maximum_key_size) {
                return Error.KeyTooLarge;
            }

            var view = PageViewType.init(try self.handle.getDataMut());
            var tmp_buf = try self.ctx.cache.getTemporaryPage();
            defer tmp_buf.deinit();

            return view.updateKey(pos, key, try tmp_buf.getDataMut());
        }

        pub fn setParent(self: *Self, parent_id: ?BlockIdType) Error!void {
            if (parent_id) |pid| {
                var view = PageViewType.init(try self.handle.getDataMut());
                view.subheaderMut().parent.set(pid);
            } else {
                var view = PageViewType.init(try self.handle.getDataMut());
                view.subheaderMut().parent.set(std.math.maxInt(BlockIdType));
            }
        }

        pub fn getParent(self: *const Self) ?BlockIdType {
            const data = self.handle.getData() catch return null;
            const view = PageViewTypeConst.init(data);
            const parent = view.subheader().parent.get();
            if (parent != std.math.maxInt(BlockIdType)) {
                return parent;
            }
            return null;
        }

        pub fn erase(self: *Self, pos: usize) Error!void {
            var view = PageViewType.init(try self.handle.getDataMut());
            var slots_dir = try view.slotsDirMut();
            return slots_dir.remove(pos);
        }
    };

    const KeyBorrowImpl = struct {
        const Self = @This();
        key: []const u8,
        ph: PageHandle,
        pub fn init(key: []const u8, ph: PageHandle) Self {
            return .{
                .key = key,
                .ph = ph,
            };
        }
        pub fn deinit(self: *Self) void {
            self.ph.deinit();
        }
    };

    const AccessorImpl = struct {
        const Self = @This();
        pub const PageCache = PageCacheType;
        const RootType = BlockIdType;

        ctx: Context = undefined,

        fn init(ctx: Context) Self {
            return .{
                .ctx = ctx,
            };
        }

        pub fn deinit(_: Self) void {
            // nothing to do yet
        }

        pub fn getRoot(self: *const Self) ?RootType {
            return self.ctx.storage_mgr.getRoot();
        }

        pub fn setRoot(self: *Self, new_root: ?RootType) !void {
            return try self.ctx.storage_mgr.setRoot(new_root);
        }

        pub fn hasRoot(self: *const Self) bool {
            return self.ctx.storage_mgr.hasRoot();
        }

        pub fn destroy(self: *Self, id: BlockIdType) !void {
            return self.ctx.storage_mgr.destroyPage(id);
        }

        pub fn createLeaf(self: *Self) !LeafImpl {
            var ph = try self.ctx.cache.create();
            defer ph.deinit();
            const pid = try ph.pid();
            var page_view = LeafImpl.PageViewType.init(try ph.getDataMut());
            try page_view.formatPage(self.ctx.settings.leaf_page_kind, pid, 0);
            return LeafImpl.init(try ph.take(), pid, &self.ctx);
        }

        pub fn createInode(self: *Self) !InodeImpl {
            var ph = try self.ctx.cache.create();
            defer ph.deinit();
            const pid = try ph.pid();
            var page_view = InodeImpl.PageViewType.init(try ph.getDataMut());
            try page_view.formatPage(self.ctx.settings.inode_page_kind, pid, 0);
            return InodeImpl.init(try ph.take(), pid, &self.ctx);
        }

        pub fn loadLeaf(self: *Self, id_opt: ?BlockIdType) !?LeafImpl {
            if (id_opt) |id| {
                var ph = try self.ctx.cache.fetch(id);
                const view = LeafImpl.PageViewTypeConst.init(try ph.getData());
                if (view.page_view.header().kind.get() != self.ctx.settings.leaf_page_kind) {
                    ph.deinit();
                    return null;
                }
                return LeafImpl.init(ph, id, &self.ctx);
            }
            return null;
        }

        pub fn loadInode(self: *Self, id_opt: ?BlockIdType) !?InodeImpl {
            if (id_opt) |id| {
                var ph = try self.ctx.cache.fetch(id);
                const view = InodeImpl.PageViewTypeConst.init(try ph.getData());
                if (view.page_view.header().kind.get() != self.ctx.settings.inode_page_kind) {
                    ph.deinit();
                    return null;
                }
                return InodeImpl.init(ph, id, &self.ctx);
            }
            return null;
        }

        pub fn isLeafId(self: *Self, id: BlockIdType) !bool {
            var ph = try self.ctx.cache.fetch(id);
            defer ph.deinit();
            const view = LeafImpl.PageViewTypeConst.init(try ph.getData());
            return (view.page_view.header().kind.get() == self.ctx.settings.leaf_page_kind);
        }

        pub fn deinitLeaf(_: *Self, leaf: ?LeafImpl) void {
            if (leaf) |l_const| {
                var l = l_const;
                l.deinit();
            }
        }

        pub fn deinitInode(_: *Self, inode: ?InodeImpl) void {
            if (inode) |i_const| {
                var i = i_const;
                i.deinit();
            }
        }

        pub fn borrowKeyfromInode(self: *Self, inode: *const InodeImpl, pos: usize) !KeyBorrowImpl {
            const view = InodeImpl.PageViewTypeConst.init(try inode.handle.getData());
            const entry = try view.get(pos);
            const key = entry.key;
            var ph = try self.ctx.cache.getTemporaryPage();

            var tmp_buf = try ph.getDataMut();
            const key_buf = tmp_buf[0..key.len];
            @memcpy(key_buf, key);

            return KeyBorrowImpl.init(key_buf, ph);
        }

        pub fn borrowKeyfromLeaf(self: *Self, leaf: *const LeafImpl, pos: usize) !KeyBorrowImpl {
            const view = LeafImpl.PageViewTypeConst.init(try leaf.handle.getData());
            const entry = try view.get(pos);
            const key = entry.key;

            var ph = try self.ctx.cache.getTemporaryPage();
            var tmp_buf = try ph.getDataMut();
            const key_buf = tmp_buf[0..key.len];

            @memcpy(key_buf, key);
            return KeyBorrowImpl.init(key_buf, ph);
        }

        pub fn deinitBorrowKey(_: *Self, key: KeyBorrowImpl) void {
            var ph = key.ph;
            ph.deinit();
        }

        pub fn canMergeLeafs(_: *Self, left: *const LeafImpl, right: *const LeafImpl) !bool {
            const view_a = LeafImpl.PageViewTypeConst.init(try left.handle.getData());
            const view_b = LeafImpl.PageViewTypeConst.init(try right.handle.getData());
            const slots_dir_a = try view_a.slotsDir();
            const slots_dir_b = try view_b.slotsDir();
            return try slots_dir_a.canMergeWith(&slots_dir_b) != .not_enough;
        }

        pub fn canMergeInodes(self: *Self, left: *const InodeImpl, right: *const InodeImpl) !bool {
            const view_a = InodeImpl.PageViewTypeConst.init(try left.handle.getData());
            const view_b = InodeImpl.PageViewTypeConst.init(try right.handle.getData());
            const slots_dir_a = try view_a.slotsDir();
            const slots_dir_b = try view_b.slotsDir();
            const additional_key_len = view_a.total_slot_size(self.ctx.settings.maximum_key_size);
            return try slots_dir_a.canMergeWithAdditional(&slots_dir_b, additional_key_len) != .not_enough;
        }
    };

    return struct {
        const Self = @This();
        pub const KeyLikeType = []const u8;
        pub const KeyOutType = []const u8;

        pub const ValueInType = []const u8;
        pub const ValueOutType = []const u8;

        pub const KeyBorrowType = KeyBorrowImpl;

        pub const BlockDeviceType = BlockDevice;
        pub const AccessorType = AccessorImpl;

        pub const Error = ErrorSet;

        pub const LeafType = LeafImpl;
        pub const InodeType = InodeImpl;

        pub const NodeIdType = BlockIdType;

        accessor: AccessorType,

        pub fn init(device: *PageCacheType, storage_mgr: *StorageManager, settings: Settings, ctx: Ctx) Self {
            const context = Context{
                .cache = device,
                .storage_mgr = storage_mgr,
                .cts = ctx,
                .settings = settings,
            };
            return .{
                .accessor = AccessorImpl.init(context),
            };
        }

        pub fn deinit() void {
            // nothing to yet
        }

        pub fn getAccessor(self: *Self) *AccessorType {
            return &self.accessor;
        }

        pub fn keyBorrowAsLike(_: *const Self, key: *const KeyBorrowType) KeyLikeType {
            return key.key;
        }

        pub fn keyOutAsLike(_: *const Self, key: KeyOutType) KeyLikeType {
            return key;
        }

        pub fn valueOutAsIn(_: *const Self, value: ValueOutType) ValueInType {
            return value;
        }

        pub fn isValidId(_: *const Self, pid: ?NodeIdType) bool {
            if (pid) |value| {
                return value != std.math.maxInt(NodeIdType);
            }
            return false;
        }
    };
}
