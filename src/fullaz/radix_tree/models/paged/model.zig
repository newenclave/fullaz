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
    inode_base: u16 = 4,
    leaf_base: u16 = 4,
};

pub fn Model(comptime PageCacheType: type, comptime StorageManager: type, comptime Key: type, comptime Value: type) type {
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
    const Index = u16;

    const ViewType = radix_page.View(BlockIdType, Index, Key, @sizeOf(Value), .little, false);
    const ConstViewType = radix_page.View(BlockIdType, Index, Key, @sizeOf(Value), .little, true);

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
                    .level = 0,
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
            return (try view.slotsCapacity());
        }

        pub fn calculateSlotCapacity(_: *const Self, page_size: usize, metadata_len: usize) usize {
            return PageViewTypeConst.calculateSlotCapacity(page_size, metadata_len);
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
            return (try view.slotsCapacity());
        }

        pub fn calculateSlotCapacity(_: *const Self, page_size: usize, metadata_len: usize) usize {
            return PageViewTypeConst.calculateSlotCapacity(page_size, metadata_len);
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

        pub const Error = ErrorSet;

        accessor: Accessor = undefined,

        pub fn init(device: *PageCacheType, storage_mgr: *StorageManager, settings: Settings) Self {
            const context = Context{
                .cache = device,
                .storage_mgr = storage_mgr,
                .settings = settings,
            };
            return .{
                .accessor = AccessorImpl.init(context),
            };
        }

        pub fn deinit(self: *Self) void {
            self.accessor.deinit();
            self.* = undefined;
        }
    };
}
