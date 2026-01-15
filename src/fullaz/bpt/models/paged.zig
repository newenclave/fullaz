const std = @import("std");
const device_interface = @import("../../device/interfaces.zig");
const page_cache = @import("../../page_cache.zig");
const bpt_page = @import("../../page/bpt.zig");

pub const Settings = struct {
    maximum_key_size: usize = 128,
    maximum_value_size: usize = 128,
};

pub fn PagedModel(comptime PageCacheType: type, comptime cmp: anytype, comptime Ctx: type) type {
    const BlockDevice = PageCacheType.UnderlyingDevice;
    const PageHandle = PageCacheType.Handle;
    const BlockIdType = BlockDevice.BlockId;

    const BptPage = bpt_page.Bpt(BlockIdType, u16, .little, false);
    const BptPageConst = bpt_page.Bpt(BlockIdType, u16, .little, true);

    const KeyType = []const u8;
    const ValueType = []const u8;

    const Context = struct {
        cts: Ctx = undefined,
        maximum_key_size: usize = 128,
        maximum_value_size: usize = 128,
    };

    const LeafImpl = struct {
        const Self = @This();
        const PageViewType = BptPage.LeafSubheaderView;
        const PageViewTypeConst = BptPageConst.LeafSubheaderView;
        handle: PageHandle = undefined,
        self_id: BlockIdType = undefined,
        cache: *PageCacheType = undefined,
        ctx: *Context = undefined,

        fn init(ph: PageHandle, self_id: BlockIdType, cache: *PageCacheType, ctx: *Context) Self {
            return .{
                .handle = ph,
                .self_id = self_id,
                .cache = cache,
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
                .cache = self.cache,
                .ctx = self.ctx,
            };
        }

        pub fn size(self: *const Self) !usize {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return try view.entries();
        }

        pub fn capacity(self: *const Self) !usize {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return (try view.slotsDir()).capacityFor(self.ctx.maximum_key_size + self.ctx.maximum_value_size);
        }

        pub fn isUnderflowed(self: *const Self) !bool {
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

        pub fn keyPosition(self: *const Self, key: KeyType) !usize {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return try view.lowerBoundWith(key, cmp, self.ctx);
        }

        pub fn getKey(self: *const Self, pos: usize) !KeyType {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return (try view.get(pos)).key;
        }

        pub fn getValue(self: *const Self, pos: usize) !ValueType {
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

        pub fn setNext(self: *Self, next_id: ?BlockIdType) !void {
            var view = PageViewType.init(try self.handle.getDataMut());
            if (next_id) |nid| {
                view.subheaderMut().next.set(nid);
            } else {
                view.subheaderMut().next.set(std.math.maxInt(BlockIdType));
            }
        }

        pub fn setPrev(self: *Self, prev_id: ?BlockIdType) !void {
            var view = PageViewType.init(try self.handle.getDataMut());
            if (prev_id) |pid| {
                view.subheaderMut().prev.set(pid);
            } else {
                view.subheaderMut().prev.set(std.math.maxInt(BlockIdType));
            }
        }

        pub fn setParent(self: *Self, parent_id: ?BlockIdType) !void {
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

        pub fn canInsertValue(self: *const Self, pos: usize, key: KeyType, value: ValueType) !bool {
            _ = pos;
            const view = PageViewTypeConst.init(try self.handle.getData());
            const total_size: usize = key.len + value.len + @sizeOf(u16); // key_size header
            return try (try view.slotsDir()).canInsert(total_size) != .not_enough;
        }

        pub fn insertValue(self: *Self, pos: usize, key: KeyType, value: ValueType) !void {
            const view = PageViewTypeConst.init(try self.handle.getData());
            const total_size: usize = key.len + value.len + @sizeOf(u16); // key_size header
            const res = try (try view.slotsDir()).canInsert(total_size);
            if (res == .not_enough) {
                return error.Full;
            } else if (res == .need_compact) {
                var view_mut = PageViewType.init(try self.handle.getDataMut());
                // TODO: check if possible to pass a buffer here to compact with the buffer
                var slots_dir = try view_mut.slotsDirMut();
                try slots_dir.compactInPlace();
            }
            var view_mut = PageViewType.init(try self.handle.getDataMut());
            try view_mut.insert(pos, key, value);
        }

        pub fn canUpdateValue(self: *const Self, pos: usize, key: KeyType, value: ValueType) !bool {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return view.canUpdateValue(pos, key, value) != .not_enough;
        }

        pub const UpdateStatus = BptPageConst.SlotsAvailableStatus;

        pub fn canUpdateValueStatus(self: *const Self, pos: usize, key: KeyType, value: ValueType) !UpdateStatus {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return view.canUpdateValue(pos, key, value);
        }

        pub fn updateValue(self: *Self, pos: usize, value: ValueType) !void {
            var tmp_page = try self.cache.getTemporaryPage();
            defer tmp_page.deinit();
            var view = PageViewType.init(try self.handle.getDataMut());
            return view.updateValue(pos, value, try tmp_page.getDataMut());
        }
    };

    const InodeImpl = struct {
        const Self = @This();
        const PageViewType = BptPage.InodeSubheaderView;
        handle: PageHandle = undefined,
        self_id: BlockIdType = undefined,

        fn init(ph: PageHandle, self_id: BlockIdType) Self {
            return .{
                .handle = ph,
                .self_id = self_id,
            };
        }

        pub fn deinit(self: *Self) void {
            self.handle.deinit();
        }

        pub fn take(self: *Self) !Self {
            return Self{
                .handle = try self.handle.take(),
                .self_id = self.self_id,
            };
        }
    };

    const KeyBorrowImpl = struct {
        const Self = @This();
        key: []const u8,
    };

    const AccessorImpl = struct {
        const Self = @This();
        pub const PageCache = PageCacheType;
        device: *PageCache = undefined,
        ctx: Context = undefined,

        fn init(device: *PageCacheType, ctx: Context) Self {
            return .{
                .device = device,
                .ctx = ctx,
            };
        }

        pub fn deinit(_: Self) void {
            // nothing to yet
        }

        pub fn createLeaf(self: *Self) !LeafImpl {
            var ph = try self.device.create();
            var page_view = LeafImpl.PageViewType.init(try ph.getDataMut());
            try page_view.formatPage(0, try ph.pid(), 0);
            return LeafImpl.init(ph, try ph.pid(), self.device, &self.ctx);
        }

        pub fn createInode(self: *Self) !InodeImpl {
            var ph = try self.device.create();
            var page_view = InodeImpl.PageViewType.init(try ph.getDataMut());
            try page_view.formatPage(1, try ph.pid(), 0);
            return InodeImpl.init(ph, try ph.pid());
        }

        pub fn loadLeaf(self: *Self, id_opt: ?BlockIdType) !?LeafImpl {
            if (id_opt) |id| {
                const ph = try self.device.fetch(id);
                return LeafImpl.init(ph, id, self.device, &self.ctx);
            }
            return null;
        }

        pub fn loadInode(self: *Self, id_opt: ?BlockIdType) !?InodeImpl {
            if (id_opt) |id| {
                const ph = try self.device.fetch(id);
                return InodeImpl.init(ph, id);
            }
            return null;
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

        pub const LeafType = LeafImpl;
        pub const InodeType = InodeImpl;

        pub const NodeIdType = BlockIdType;

        accessor: AccessorType,

        pub fn init(device: *PageCacheType, settings: Settings, ctx: Ctx) Self {
            const context = Context{
                .cts = ctx,
                .maximum_key_size = settings.maximum_key_size,
                .maximum_value_size = settings.maximum_value_size,
            };
            return .{
                .accessor = AccessorImpl.init(device, context),
            };
        }

        pub fn deinit() void {
            // nothing to yet
        }

        pub fn getAccessor(self: *Self) *AccessorType {
            return &self.accessor;
        }
    };
}
