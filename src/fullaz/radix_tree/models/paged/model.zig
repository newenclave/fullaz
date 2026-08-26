const std = @import("std");
const device_interface = @import("../../../device/interfaces.zig");
const page_cache = @import("../../../storage/storage.zig").page_cache;
const radix_page = @import("view.zig");
const contracts = @import("../../../contracts/contracts.zig");
const core = @import("../../../core/core.zig");
const errors = core.errors;
const header = @import("../../../page/header.zig");
const KeySplitter = @import("../../splitter.zig").Splitter;

const SettingsImpl = struct {
    leaf_page_kind: u16 = 0,
    inode_page_kind: u16 = 1,
    inode_base: u16 = 0,
    leaf_base: u16 = 0,
};

pub fn Model(comptime PageCacheT: type, comptime StorageManagerT: type, comptime KeyT: type, comptime ValueSize: usize) type {
    comptime {
        contracts.storage_manager.requiresStorageManager(StorageManagerT);
        contracts.page_cache.requiresPageCache(PageCacheT);
    }

    const Context = struct {
        cache: *PageCacheT = undefined,
        storage_mgr: *StorageManagerT = undefined,
        settings: SettingsImpl = undefined,
    };

    const ErrorSet = errors.PageError ||
        errors.SlotsError ||
        PageCacheT.Error ||
        StorageManagerT.Error ||
        errors.BufferError ||
        errors.SpaceError ||
        errors.OrderError ||
        header.ValidationError ||
        error{InvalidSettings};

    const BlockDevice = PageCacheT.UnderlyingDevice;
    const PageHandle = PageCacheT.Handle;
    const BlockIdType = BlockDevice.BlockId;
    const RawPageId = BlockIdType;
    const Index = u16;
    const InputValue = []const u8;
    const OutputValue = InputValue;

    const ViewType = radix_page.View(RawPageId, Index, KeyT, ValueSize, .little, false);
    const ConstViewType = radix_page.View(RawPageId, Index, KeyT, ValueSize, .little, true);

    const SplitterType = KeySplitter(KeyT);

    const SplitKeyImpl = struct {
        const Self = @This();
        pub const KeyDigitType = SplitterType.Result;
        const KeyDigit = KeyDigitType;
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
        const ConstPageViewType = ConstViewType.LeafSubheaderView;

        handle: PageHandle = undefined,
        self_id: RawPageId = undefined,
        ctx: *Context = undefined,

        pub const Error = ErrorSet;

        fn init(ph: PageHandle, self_id: RawPageId, ctx: *Context) Self {
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
            const view = ConstPageViewType.init(try self.handle.data());
            return (try view.size());
        }

        pub fn capacity(self: *const Self) Error!usize {
            const view = ConstPageViewType.init(try self.handle.data());
            return (try view.capacity());
        }

        pub fn calculateSlotCapacity(_: *const Self, page_size: usize, metadata_len: usize) usize {
            return ConstPageViewType.calculateSlotCapacity(page_size, metadata_len);
        }

        pub fn set(self: *Self, key: KeyT, value: InputValue) Error!void {
            var view = PageViewType.init(try self.handle.dataMut());
            try view.set(key, value);
        }

        pub fn get(self: *const Self, key: KeyT) Error!OutputValue {
            var view = ConstPageViewType.init(try self.handle.data());
            return try view.get(key);
        }

        pub fn isSet(self: *const Self, key: KeyT) Error!bool {
            var view = ConstPageViewType.init(try self.handle.data());
            return try view.isSet(key);
        }

        pub fn free(self: *Self, key: KeyT) ErrorSet!void {
            var view = PageViewType.init(try self.handle.dataMut());
            try view.free(key);
        }

        pub fn setParent(self: *Self, parent_id: ?RawPageId) ErrorSet!void {
            var view = PageViewType.init(try self.handle.dataMut());
            try view.setParent(parent_id);
        }

        pub fn getParent(self: *const Self) ErrorSet!?RawPageId {
            var view = ConstPageViewType.init(try self.handle.data());
            return try view.getParent();
        }

        pub fn setParentQuotient(self: *Self, quotient: KeyT) ErrorSet!void {
            var view = PageViewType.init(try self.handle.dataMut());
            try view.setParentQuotient(quotient);
        }

        pub fn getParentQuotient(self: *const Self) ErrorSet!KeyT {
            var view = ConstPageViewType.init(try self.handle.data());
            return view.subheader().parent_quotient.get();
        }

        pub fn setParentId(self: *Self, idx: KeyT) ErrorSet!void {
            var view = PageViewType.init(try self.handle.dataMut());
            try view.setParentIdx(idx);
        }

        pub fn getParentId(self: *const Self) ErrorSet!KeyT {
            var view = ConstPageViewType.init(try self.handle.data());
            return try view.getParentIdx();
        }
    };

    const InodeImpl = struct {
        const Self = @This();
        const PageViewType = ViewType.InodeSubheaderView;
        const ConstPageViewType = ConstViewType.InodeSubheaderView;

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
            const view = ConstPageViewType.init(try self.handle.data());
            return (try view.size());
        }

        pub fn capacity(self: *const Self) Error!usize {
            const view = ConstPageViewType.init(try self.handle.data());
            return (try view.capacity());
        }

        pub fn calculateSlotCapacity(_: *const Self, page_size: usize, metadata_len: usize) usize {
            return ConstPageViewType.calculateSlotCapacity(page_size, metadata_len);
        }

        pub fn set(self: *Self, key: KeyT, child_id: RawPageId) Error!void {
            var view = PageViewType.init(try self.handle.dataMut());
            try view.set(key, child_id);
        }

        pub fn get(self: *const Self, key: KeyT) Error!RawPageId {
            var view = ConstPageViewType.init(try self.handle.data());
            return try view.get(key);
        }

        pub fn isSet(self: *const Self, key: KeyT) Error!bool {
            var view = ConstPageViewType.init(try self.handle.data());
            return try view.isSet(key);
        }

        pub fn free(self: *Self, key: KeyT) ErrorSet!void {
            var view = PageViewType.init(try self.handle.dataMut());
            try view.free(key);
        }

        pub fn setParent(self: *Self, parent_id: ?RawPageId) ErrorSet!void {
            var view = PageViewType.init(try self.handle.dataMut());
            try view.setParent(parent_id);
        }

        pub fn getParent(self: *const Self) ErrorSet!?RawPageId {
            var view = ConstPageViewType.init(try self.handle.data());
            return try view.getParent();
        }

        pub fn setParentQuotient(self: *Self, quotient: KeyT) ErrorSet!void {
            var view = PageViewType.init(try self.handle.dataMut());
            try view.setParentQuotient(quotient);
        }

        pub fn getParentQuotient(self: *const Self) ErrorSet!KeyT {
            var view = ConstPageViewType.init(try self.handle.data());
            return try view.getParentQuotient();
        }

        pub fn setParentId(self: *Self, idx: KeyT) ErrorSet!void {
            var view = PageViewType.init(try self.handle.dataMut());
            try view.setParentIdx(idx);
        }

        pub fn getParentId(self: *const Self) ErrorSet!KeyT {
            var view = ConstPageViewType.init(try self.handle.data());
            return try view.getParentIdx();
        }

        pub fn setLevel(self: *Self, level: usize) ErrorSet!void {
            var view = PageViewType.init(try self.handle.dataMut());
            try view.setLevel(level);
        }

        pub fn getLevel(self: *const Self) ErrorSet!usize {
            var view = ConstPageViewType.init(try self.handle.data());
            return try view.getLevel();
        }
    };

    const AccessorImpl = struct {
        const Self = @This();
        pub const Error = ErrorSet;
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

        pub fn getRoot(self: *const Self) ErrorSet!?RawPageId {
            const root_id = self.ctx.storage_mgr.getRoot();
            if (root_id) |id| {
                return id;
            }
            return null;
        }

        pub fn setRoot(self: *Self, pid: ?RawPageId) ErrorSet!void {
            try self.ctx.storage_mgr.setRoot(pid);
        }

        pub fn getRootLevel(self: *const Self) ErrorSet!?usize {
            const root_id = try self.getRoot();
            if (root_id) |id| {
                var ph = try self.ctx.cache.fetch(id);
                defer ph.deinit();
                const pid = try ph.pid();
                const page_data = try ph.data();
                const page_view = ConstViewType.PageViewType.init(page_data);
                try page_view.validateTyped();
                if (page_view.header().self_pid.get() != pid) {
                    return Error.BadData;
                }
                if (page_view.header().kind.get() == self.ctx.settings.leaf_page_kind) {
                    const view = ConstViewType.LeafSubheaderView.init(page_data);
                    try view.check();
                    return 0;
                }
                if (page_view.header().kind.get() == self.ctx.settings.inode_page_kind) {
                    const view = ConstViewType.InodeSubheaderView.init(page_data);
                    try view.check();
                    return try view.getLevel();
                }
                return Error.BadType;
            }
            return null;
        }

        pub fn createLeaf(self: *Self) ErrorSet!LeafImpl {
            var ph = try self.ctx.cache.create();
            defer ph.deinit();
            const pid = try ph.pid();
            var page_view = LeafImpl.PageViewType.init(try ph.dataMut());
            try page_view.formatPage(self.ctx.settings.leaf_page_kind, pid, 0);
            return LeafImpl.init(try ph.take(), pid, &self.ctx);
        }

        pub fn loadLeaf(self: *Self, id: BlockIdType) ErrorSet!LeafImpl {
            var ph = try self.ctx.cache.fetch(id);
            defer ph.deinit();
            const pid = try ph.pid();
            var view = LeafImpl.ConstPageViewType.init(try ph.data());
            if (view.page_view.header().kind.get() != self.ctx.settings.leaf_page_kind) {
                return Error.BadType;
            }
            try view.check();
            if (view.page_view.header().self_pid.get() != pid) {
                return Error.BadData;
            }
            return LeafImpl.init(try ph.take(), pid, &self.ctx);
        }

        pub fn deinitLeaf(_: *Self, leaf: *LeafImpl) void {
            leaf.deinit();
            leaf.* = undefined;
        }

        pub fn isLeaf(self: *const Self, id: BlockIdType) ErrorSet!bool {
            var ph = try self.ctx.cache.fetch(id);
            defer ph.deinit();
            const pid = try ph.pid();
            var view = LeafImpl.ConstPageViewType.init(try ph.data());
            try view.page_view.validateTyped();
            if (view.page_view.header().self_pid.get() != pid) {
                return Error.BadData;
            }
            return view.page_view.header().kind.get() == self.ctx.settings.leaf_page_kind;
        }

        pub fn createInode(self: *Self) ErrorSet!InodeImpl {
            var ph = try self.ctx.cache.create();
            defer ph.deinit();
            const pid = try ph.pid();
            var page_view = InodeImpl.PageViewType.init(try ph.dataMut());
            try page_view.formatPage(self.ctx.settings.inode_page_kind, pid, 0);
            return InodeImpl.init(try ph.take(), pid, &self.ctx);
        }

        pub fn loadInode(self: *Self, id: BlockIdType) ErrorSet!InodeImpl {
            var ph = try self.ctx.cache.fetch(id);
            defer ph.deinit();
            const pid = try ph.pid();
            var view = InodeImpl.ConstPageViewType.init(try ph.data());
            if (view.page_view.header().kind.get() != self.ctx.settings.inode_page_kind) {
                return Error.BadType;
            }
            try view.check();
            if (view.page_view.header().self_pid.get() != pid) {
                return Error.BadData;
            }
            return InodeImpl.init(try ph.take(), pid, &self.ctx);
        }

        pub fn deinitInode(_: *Self, inode: *InodeImpl) void {
            inode.deinit();
            inode.* = undefined;
        }

        pub fn splitKey(self: *const Self, key: KeyT) Error!SplitKeyResult {
            const maximum_levels = self.splitter.maximum_levels;
            var tmp_page = try self.ctx.cache.getTemporaryPage();
            errdefer tmp_page.deinit();

            var aligned_slice = try sliceAligned(try tmp_page.dataMut(), maximum_levels);

            const res = try self.splitter.split(key, aligned_slice);
            return SplitKeyResult.init(tmp_page, aligned_slice[0..res.len]);
        }

        pub fn deinitSplitKey(_: *Self, sk: *SplitKeyResult) void {
            sk.deinit();
        }

        pub fn destroy(self: *Self, page_id: RawPageId) ErrorSet!void {
            try self.ctx.storage_mgr.destroyPage(page_id);
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
        pub const Settings = SettingsImpl;
        pub const LeafType = LeafImpl;
        pub const InodeType = InodeImpl;
        pub const AccessorType = AccessorImpl;
        pub const SplitKeyType = AccessorType.SplitKeyResult;
        pub const KeyInType = KeyT;
        pub const KeyOutType = KeyT;
        pub const ValueInType = []const u8;
        pub const ValueOutType = ValueInType;
        pub const NodeIdType = RawPageId;
        pub const PageId = BlockIdType;

        pub const Error = ErrorSet;

        accessor_state: AccessorType = undefined,

        pub fn init(device: *PageCacheT, storage_mgr: *StorageManagerT, settings: Settings) Error!Self {
            const page_size = device.pageSize();
            const minimum_leaf_page_size = ViewType.PageViewType.header_size +
                @sizeOf(ViewType.LeafSubheader);
            const minimum_inode_page_size = ViewType.PageViewType.header_size +
                @sizeOf(ViewType.InodeSubheader);
            if (page_size <= minimum_leaf_page_size or page_size <= minimum_inode_page_size) {
                return error.InvalidSettings;
            }
            const inode_base = InodeType.ConstPageViewType.calculateSlotCapacity(device.pageSize(), 0);
            const leaf_base = LeafType.ConstPageViewType.calculateSlotCapacity(device.pageSize(), 0);
            if (inode_base < 2 or leaf_base < 2 or
                inode_base > std.math.maxInt(u16) or leaf_base > std.math.maxInt(u16))
            {
                return error.InvalidSettings;
            }

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
                .accessor_state = AccessorImpl.init(context),
            };
        }

        pub fn deinit(self: *Self) void {
            self.accessor_state.deinit();
            self.* = undefined;
        }

        pub fn scanInodeRefs(
            self: *const Self,
            page_id: PageId,
            page: []const u8,
            visitor: anytype,
        ) !void {
            const view = ConstViewType.InodeSubheaderView.init(page);
            const settings = self.accessor_state.ctx.settings;
            try view.validatePage(page_id, settings.inode_page_kind);
            const slots = try view.slotsDir();
            for (0..try slots.capacity()) |index| {
                if (try slots.isSet(index)) {
                    try visitor.visit(try view.getAt(index));
                }
            }
        }

        pub fn scanLeafRefs(
            self: *const Self,
            page_id: PageId,
            page: []const u8,
            visitor: anytype,
        ) !void {
            const view = ConstViewType.LeafSubheaderView.init(page);
            const settings = self.accessor_state.ctx.settings;
            try view.validatePage(page_id, settings.leaf_page_kind);
            if (visitor.hasValueScanner()) {
                const slots = try view.slotsDir();
                for (0..try slots.capacity()) |index| {
                    if (try slots.isSet(index)) {
                        try visitor.visitValue(try slots.get(index));
                    }
                }
            }
        }

        pub fn effectiveSettings(self: *const Self) Settings {
            return self.accessor_state.ctx.settings;
        }

        pub fn getSettings(self: *const Self) *const Settings {
            return &self.accessor_state.ctx.settings;
        }

        pub fn accessor(self: *Self) *AccessorType {
            return &self.accessor_state;
        }
    };
}
