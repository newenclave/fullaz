const std = @import("std");
const device_interface = @import("../../../device/interfaces.zig");
const page_cache = @import("../../../storage/page_cache.zig");
const radix_page = @import("view.zig");
const contracts = @import("../../../contracts/contracts.zig");
const core = @import("../../../core/core.zig");
const errors = core.errors;
const KeySplitter = @import("../../splitter.zig").Splitter;

pub const Settings = struct {
    leaf_page_kind: u16 = 0,
    inode_page_kind: u16 = 1,
    inode_base: u16 = 0,
    leaf_base: u16 = 0,
};

pub fn Model(comptime PageCacheType: type, comptime StorageManager: type, comptime Key: type, comptime ValueSize: usize) type {
    comptime {
        contracts.storage_manager.requiresStorageManager(StorageManager);
        contracts.page_cache.requiresPageCache(PageCacheType);
    }

    const Context = struct {
        cache: *PageCacheType = undefined,
        storage_mgr: *StorageManager = undefined,
        settings: Settings = undefined,
    };

    const ErrorSet = errors.PageError ||
        errors.SlotsError ||
        PageCacheType.Error ||
        errors.BufferError ||
        errors.SpaceError ||
        errors.OrderError;

    const BlockDevice = PageCacheType.UnderlyingDevice;
    const PageHandle = PageCacheType.Handle;
    const BlockIdType = BlockDevice.BlockId;
    const PageId = BlockIdType;
    const Index = u16;
    const ValueInType = []const u8;
    const ValueOutType = ValueInType;

    const ViewType = radix_page.View(PageId, Index, Key, ValueSize, .little, false);
    const ConstViewType = radix_page.View(PageId, Index, Key, ValueSize, .little, true);

    const SplitterType = KeySplitter(Key);

    const SplitKeyImpl = struct {
        const Self = @This();
        const KeyDigit = SplitterType.Result;
        handle: PageHandle = undefined,
        items: []KeyDigit = undefined,

        const Error = ErrorSet;

        fn init(handle: PageHandle, items: []KeyDigit) Error!Self {
            return Self{
                .handle = handle,
                .items = items,
            };
        }

        fn deinit(self: *Self) void {
            self.handle.deinit();
            self.* = undefined;
        }

        pub fn size(self: *const Self) usize {
            return self.items.len;
        }

        pub fn empty(self: *const Self) bool {
            return self.items.len == 0;
        }

        pub fn get(self: *const Self, idx: usize) KeyDigit {
            if (idx >= self.items.len) {
                return .{
                    .digit = 0,
                    .quotient = 0,
                    .level = idx,
                };
            }
            return self.items[idx];
        }
    };

    const LeafImpl = struct {
        const Self = @This();
        const PageViewType = ViewType.LeafSubheaderView;
        const PageViewTypeConst = ConstViewType.LeafSubheaderView;

        handle: PageHandle = undefined,
        self_id: PageId = undefined,
        ctx: *Context = undefined,

        pub const Error = ErrorSet;

        fn init(ph: PageHandle, self_id: PageId, ctx: *Context) Self {
            return .{
                .handle = ph,
                .self_id = self_id,
                .ctx = ctx,
            };
        }

        fn deinit(self: *Self) void {
            self.handle.deinit();
            self.* = undefined;
        }

        pub fn id(self: *const Self) BlockIdType {
            return self.self_id;
        }

        pub fn size(self: *const Self) Error!usize {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return (try view.size());
        }

        pub fn capacity(self: *const Self) Error!usize {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return (try view.capacity());
        }

        pub fn calculateSlotCapacity(_: *const Self, page_size: usize, metadata_len: usize) usize {
            return PageViewTypeConst.calculateSlotCapacity(page_size, metadata_len);
        }

        pub fn set(self: *Self, key: Key, value: ValueInType) Error!void {
            var view = PageViewType.init(try self.handle.getDataMut());
            try view.set(key, value);
        }

        pub fn get(self: *const Self, key: Key) Error!ValueOutType {
            var view = PageViewTypeConst.init(try self.handle.getData());
            return try view.get(key);
        }

        pub fn isSet(self: *const Self, key: Key) Error!bool {
            var view = PageViewTypeConst.init(try self.handle.getData());
            return try view.isSet(key);
        }

        pub fn free(self: *Self, key: Key) ErrorSet!void {
            var view = PageViewType.init(try self.handle.getDataMut());
            try view.free(key);
        }

        pub fn setParent(self: *Self, parent_id: ?PageId) ErrorSet!void {
            var view = PageViewType.init(try self.handle.getDataMut());
            try view.setParent(parent_id);
        }

        pub fn getParent(self: *const Self) ErrorSet!?PageId {
            var view = PageViewTypeConst.init(try self.handle.getData());
            return try view.getParent();
        }

        pub fn setParentQuotient(self: *Self, quotient: Key) ErrorSet!void {
            var view = PageViewType.init(try self.handle.getDataMut());
            try view.setParentQuotient(quotient);
        }

        pub fn getParentQuotient(self: *const Self) ErrorSet!Key {
            var view = PageViewTypeConst.init(try self.handle.getData());
            return view.subheader().parent_quotient.get();
        }

        pub fn setParentId(self: *Self, idx: Key) ErrorSet!void {
            var view = PageViewType.init(try self.handle.getDataMut());
            try view.setParentIdx(idx);
        }

        pub fn getParentId(self: *const Self) ErrorSet!Key {
            var view = PageViewTypeConst.init(try self.handle.getData());
            return try view.getParentIdx();
        }
    };

    const InodeImpl = struct {
        const Self = @This();
        const PageViewType = ViewType.InodeSubheaderView;
        const PageViewTypeConst = ConstViewType.InodeSubheaderView;

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

        fn deinit(self: *Self) void {
            self.handle.deinit();
            self.* = undefined;
        }

        pub fn id(self: *const Self) BlockIdType {
            return self.self_id;
        }

        pub fn size(self: *const Self) Error!usize {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return (try view.size());
        }

        pub fn capacity(self: *const Self) Error!usize {
            const view = PageViewTypeConst.init(try self.handle.getData());
            return (try view.capacity());
        }

        pub fn calculateSlotCapacity(_: *const Self, page_size: usize, metadata_len: usize) usize {
            return PageViewTypeConst.calculateSlotCapacity(page_size, metadata_len);
        }

        pub fn set(self: *Self, key: Key, child_id: PageId) Error!void {
            var view = PageViewType.init(try self.handle.getDataMut());
            try view.set(key, child_id);
        }

        pub fn get(self: *const Self, key: Key) Error!PageId {
            var view = PageViewTypeConst.init(try self.handle.getData());
            return try view.get(key);
        }

        pub fn isSet(self: *const Self, key: Key) Error!bool {
            var view = PageViewTypeConst.init(try self.handle.getData());
            return try view.isSet(key);
        }

        pub fn free(self: *Self, key: Key) ErrorSet!void {
            var view = PageViewType.init(try self.handle.getDataMut());
            try view.free(key);
        }

        pub fn setParent(self: *Self, parent_id: ?PageId) ErrorSet!void {
            var view = PageViewType.init(try self.handle.getDataMut());
            try view.setParent(parent_id);
        }

        pub fn getParent(self: *const Self) ErrorSet!?PageId {
            var view = PageViewTypeConst.init(try self.handle.getData());
            return try view.getParent();
        }

        pub fn setParentQuotient(self: *Self, quotient: Key) ErrorSet!void {
            var view = PageViewType.init(try self.handle.getDataMut());
            try view.setParentQuotient(quotient);
        }

        pub fn getParentQuotient(self: *const Self) ErrorSet!Key {
            var view = PageViewTypeConst.init(try self.handle.getData());
            return try view.getParentQuotient();
        }

        pub fn setParentId(self: *Self, idx: Key) ErrorSet!void {
            var view = PageViewType.init(try self.handle.getDataMut());
            try view.setParentIdx(idx);
        }

        pub fn getParentId(self: *const Self) ErrorSet!Key {
            var view = PageViewTypeConst.init(try self.handle.getData());
            return try view.getParentIdx();
        }

        pub fn setLevel(self: *Self, level: usize) ErrorSet!void {
            var view = PageViewType.init(try self.handle.getDataMut());
            try view.setLevel(level);
        }

        pub fn getLevel(self: *const Self) ErrorSet!usize {
            var view = PageViewTypeConst.init(try self.handle.getData());
            return try view.getLevel();
        }
    };

    const AccessorImpl = struct {
        const Self = @This();
        const Error = ErrorSet;
        const SplitKeyResult = SplitKeyImpl;
        const KeyDigit = SplitterType.Result;

        ctx: Context = undefined,
        splitter: SplitterType = undefined,

        fn init(ctx: Context) Self {
            return .{
                .ctx = ctx,
                .splitter = SplitterType.init(ctx.settings.inode_base, ctx.settings.leaf_base),
            };
        }

        fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn getRoot(self: *const Self) ErrorSet!?PageId {
            const root_id = self.ctx.storage_mgr.getRoot();
            if (root_id) |id| {
                return id;
            }
            return null;
        }

        pub fn setRoot(self: *const Self, pid: ?PageId) ErrorSet!void {
            try self.ctx.storage_mgr.setRoot(pid);
        }

        pub fn getRootLevel(self: *const Self) ErrorSet!?usize {
            const root_id = try self.getRoot();
            if (root_id) |id| {
                var ph = try self.ctx.cache.fetch(id);
                defer ph.deinit();
                var view = ConstViewType.InodeSubheaderView.init(try ph.getData());
                try view.check();
                return try view.getLevel();
            }
            return null;
        }

        pub fn createLeaf(self: *Self) ErrorSet!LeafImpl {
            var ph = try self.ctx.cache.create();
            defer ph.deinit();
            const pid = try ph.pid();
            var page_view = LeafImpl.PageViewType.init(try ph.getDataMut());
            try page_view.formatPage(self.ctx.settings.leaf_page_kind, pid, 0);
            return LeafImpl.init(try ph.take(), pid, &self.ctx);
        }

        pub fn loadLeaf(self: *Self, id: BlockIdType) ErrorSet!LeafImpl {
            var ph = try self.ctx.cache.fetch(id);
            defer ph.deinit();
            const pid = try ph.pid();
            var view = LeafImpl.PageViewTypeConst.init(try ph.getData());
            if (view.page_view.header().kind.get() != self.ctx.settings.leaf_page_kind) {
                return Error.BadType;
            }
            try view.check();
            return LeafImpl.init(try ph.take(), pid, &self.ctx);
        }

        pub fn deinitLeaf(_: *Self, leaf: *LeafImpl) void {
            leaf.deinit();
            leaf.* = undefined;
        }

        pub fn isLeaf(self: *const Self, id: BlockIdType) ErrorSet!bool {
            var ph = try self.ctx.cache.fetch(id);
            defer ph.deinit();
            var view = LeafImpl.PageViewTypeConst.init(try ph.getData());
            return view.page_view.header().kind.get() == self.ctx.settings.leaf_page_kind;
        }

        pub fn createInode(self: *Self) ErrorSet!InodeImpl {
            var ph = try self.ctx.cache.create();
            defer ph.deinit();
            const pid = try ph.pid();
            var page_view = InodeImpl.PageViewType.init(try ph.getDataMut());
            try page_view.formatPage(self.ctx.settings.inode_page_kind, pid, 0);
            return InodeImpl.init(try ph.take(), pid, &self.ctx);
        }

        pub fn loadInode(self: *Self, id: BlockIdType) ErrorSet!InodeImpl {
            var ph = try self.ctx.cache.fetch(id);
            defer ph.deinit();
            const pid = try ph.pid();
            var view = InodeImpl.PageViewTypeConst.init(try ph.getData());
            if (view.page_view.header().kind.get() != self.ctx.settings.inode_page_kind) {
                return Error.BadType;
            }
            try view.check();
            return InodeImpl.init(try ph.take(), pid, &self.ctx);
        }

        pub fn deinitInode(_: *Self, inode: *InodeImpl) void {
            inode.deinit();
            inode.* = undefined;
        }

        pub fn splitKey(self: *const Self, key: Key) Error!SplitKeyResult {
            const maximum_levels = self.splitter.maximum_levels;
            var tmp_page = try self.ctx.cache.getTemporaryPage();
            errdefer tmp_page.deinit();

            var aligned_slice = try sliceAligned(try tmp_page.getDataMut(), maximum_levels);

            const res = try self.splitter.split(key, aligned_slice);
            return SplitKeyResult.init(tmp_page, aligned_slice[0..res.len]);
        }

        pub fn deinitSplitKey(_: *Self, sk: *SplitKeyResult) void {
            sk.deinit();
        }

        pub fn destroy(_: *Self, _: PageId) ErrorSet!void {
            //try self.ctx.storage_mgr.destroy(pid);
            // TODO: implement destroy and use it in freeChild
        }

        fn sliceAligned(buf: []u8, n: usize) Error![]KeyDigit {
            if (core.memory.sliceAligned(KeyDigit, buf, n)) |slice| {
                return slice;
            }
            return Error.BufferTooSmall;
        }
    };

    return struct {
        const Self = @This();
        pub const Leaf = LeafImpl;
        pub const Inode = InodeImpl;
        pub const Accessor = AccessorImpl;
        pub const SplitKeyResult = Accessor.SplitKeyResult;
        pub const KeyIn = Key;
        pub const KeyOut = Key;
        pub const ValueIn = ValueInType;
        pub const ValueOut = ValueOutType;
        pub const Pid = PageId;

        pub const Error = ErrorSet;

        accessor: Accessor = undefined,

        pub fn init(device: *PageCacheType, storage_mgr: *StorageManager, settings: Settings) Self {
            const inode_base = Inode.PageViewTypeConst.calculateSlotCapacity(device.pageSize(), 0);
            const leaf_base = Leaf.PageViewTypeConst.calculateSlotCapacity(device.pageSize(), 0);

            const context = Context{
                .cache = device,
                .storage_mgr = storage_mgr,
                .settings = .{
                    .leaf_page_kind = settings.leaf_page_kind,
                    .inode_page_kind = settings.inode_page_kind,
                    // .inode_base = settings.inode_base,
                    // .leaf_base = settings.leaf_base,
                    .inode_base = @as(u16, @intCast(inode_base)),
                    .leaf_base = @as(u16, @intCast(leaf_base)),
                },
            };
            return .{
                .accessor = AccessorImpl.init(context),
            };
        }

        pub fn deinit(self: *Self) void {
            self.accessor.deinit();
            self.* = undefined;
        }

        pub fn effectiveSettings(self: *const Self) Settings {
            return self.accessor.ctx.settings;
        }

        pub fn getSettings(self: *const Self) *const Settings {
            return &self.accessor.ctx.settings;
        }
    };
}
