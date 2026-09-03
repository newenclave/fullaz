const std = @import("std");
const radix_page = @import("view.zig");
const contracts = @import("../../../contracts/contracts.zig");
const core = @import("../../../core/core.zig");
const errors = core.errors;
const header = @import("../../../page/header.zig");
const KeySplitter = @import("../../splitter.zig").Splitter;
const model_interfaces = @import("../interfaces.zig");
const StructuralMutationCoordinator = core.structural_mutation.StructuralMutationCoordinator;
const StructuralMutationError = core.structural_mutation.Error;

/// Durable state required to reopen one paged Radix tree.
pub fn State(comptime PageIdT: type, comptime endian: std.builtin.Endian) type {
    const PackedPageId = core.packed_int.PackedInt(PageIdT, endian);
    const StateImpl = extern struct {
        root: PackedPageId = PackedPageId.init(PackedPageId.max),
        free_leaf_root: PackedPageId = PackedPageId.init(PackedPageId.max),
    };

    comptime {
        if (@alignOf(StateImpl) != 1 or
            @offsetOf(StateImpl, "root") != 0 or
            @offsetOf(StateImpl, "free_leaf_root") != @sizeOf(PackedPageId) or
            @sizeOf(StateImpl) != 2 * @sizeOf(PackedPageId))
        {
            @compileError("RadixTree paged state layout changed");
        }
    }
    return StateImpl;
}

const SettingsImpl = struct {
    leaf_page_kind: u16 = 0,
    inode_page_kind: u16 = 1,
    inode_base: u16 = 0,
    leaf_base: u16 = 0,
};

pub fn Model(comptime PageCacheT: type, comptime StorageManagerT: type, comptime KeyT: type, comptime ValueSize: usize) type {
    comptime {
        contracts.storage_manager.assertPagedStorageManager(StorageManagerT, PageCacheT.Pid);
        contracts.page_cache.requiresPageCache(PageCacheT);
    }

    const StateImpl = State(PageCacheT.Pid, .little);
    const StateLeaseT = StorageManagerT.StateLeaseType;
    const StateView = core.storage_manager.StateAccessor(StateLeaseT, StateImpl);

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
        StateView.Error ||
        error{InvalidSettings} ||
        StructuralMutationError;

    const PageHandle = PageCacheT.Handle;
    const CachePageId = PageCacheT.Pid;
    const RawPageId = CachePageId;
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

        pub fn id(self: *const Self) CachePageId {
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

        pub fn getFirstFree(self: *const Self) Error!?KeyT {
            const view = ConstPageViewType.init(try self.handle.data());
            return try view.getFirstFree();
        }

        pub fn isInFree(self: *const Self) Error!bool {
            const view = ConstPageViewType.init(try self.handle.data());
            return try view.isInFree();
        }

        fn getNextFreeLeaf(self: *const Self) Error!?RawPageId {
            const view = ConstPageViewType.init(try self.handle.data());
            return try view.getNextFreeLeaf();
        }

        fn getPrevFreeLeaf(self: *const Self) Error!?RawPageId {
            const view = ConstPageViewType.init(try self.handle.data());
            return try view.getPrevFreeLeaf();
        }

        fn setFreeLeafLinks(self: *Self, prev: ?RawPageId, next: ?RawPageId) Error!void {
            var view = PageViewType.init(try self.handle.dataMut());
            try view.setFreeLeafLinks(prev, next);
        }

        fn setPrevFreeLeaf(self: *Self, page_id: ?RawPageId) Error!void {
            var view = PageViewType.init(try self.handle.dataMut());
            try view.setPrevFreeLeaf(page_id);
        }

        fn setNextFreeLeaf(self: *Self, page_id: ?RawPageId) Error!void {
            var view = PageViewType.init(try self.handle.dataMut());
            try view.setNextFreeLeaf(page_id);
        }

        fn clearFreeLeaf(self: *Self) Error!void {
            var view = PageViewType.init(try self.handle.dataMut());
            view.clearFreeLeaf();
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
        self_id: CachePageId = undefined,
        ctx: *Context = undefined,

        pub const Error = ErrorSet;

        fn init(ph: PageHandle, self_id: CachePageId, ctx: *Context) Self {
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

        pub fn id(self: *const Self) CachePageId {
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
        const ValueEditorImpl = struct {
            const EditorSelf = @This();

            pub const Error = ErrorSet;
            pub const ValueMutType = []u8;

            layout_lock: ?PageHandle.LayoutLock,
            snapshot: ?PageHandle,
            key: KeyT,
            value_len: usize,
            coordinator: *StructuralMutationCoordinator,
            open: bool = true,

            fn init(
                layout_lock: PageHandle.LayoutLock,
                snapshot: PageHandle,
                key: KeyT,
                value_len: usize,
                coordinator: *StructuralMutationCoordinator,
            ) EditorSelf {
                return .{
                    .layout_lock = layout_lock,
                    .snapshot = snapshot,
                    .key = key,
                    .value_len = value_len,
                    .coordinator = coordinator,
                };
            }

            pub fn valueMut(self: *EditorSelf) ErrorSet!ValueMutType {
                try self.ensureOpen();
                if (self.layout_lock) |*layout_lock| {
                    var view = LeafImpl.PageViewType.init(try layout_lock.dataMut());
                    const value = try view.valueMut(self.key);
                    if (value.len != self.value_len) {
                        return error.EditorInvalidated;
                    }
                    return value;
                }
                return error.EditorInvalidated;
            }

            pub fn finish(self: *EditorSelf) ErrorSet!void {
                try self.ensureOpen();
                self.close();
            }

            pub fn deinit(self: *EditorSelf) void {
                if (!self.open) {
                    return;
                }
                self.restore() catch @panic("RadixTree value editor rollback failed");
                self.close();
            }

            fn ensureOpen(self: *const EditorSelf) ErrorSet!void {
                if (!self.open) {
                    return error.EditorInvalidated;
                }
            }

            fn restore(self: *EditorSelf) ErrorSet!void {
                if (self.layout_lock) |*layout_lock| {
                    if (self.snapshot) |*snapshot| {
                        const snapshot_bytes = try snapshot.data();
                        var view = LeafImpl.PageViewType.init(try layout_lock.dataMut());
                        const value = try view.valueMut(self.key);
                        if (value.len != self.value_len) {
                            return error.EditorInvalidated;
                        }
                        @memcpy(value, snapshot_bytes[0..self.value_len]);
                        return;
                    }
                }
                return error.EditorInvalidated;
            }

            fn close(self: *EditorSelf) void {
                if (self.layout_lock) |*layout_lock| {
                    layout_lock.deinit();
                    self.layout_lock = null;
                }
                if (self.snapshot) |*snapshot| {
                    snapshot.deinit();
                    self.snapshot = null;
                }
                self.coordinator.finishValueEditor();
                self.open = false;
            }
        };

        pub const ValueEditorType = ValueEditorImpl;
        const SplitKeyResult = SplitKeyImpl;
        const KeyDigit = SplitterType.Result;

        ctx: Context = undefined,
        splitter: SplitterType = undefined,
        coordinator: StructuralMutationCoordinator = .{},

        fn init(ctx: Context) Self {
            return .{
                .ctx = ctx,
                .splitter = SplitterType.init(ctx.settings.inode_base, ctx.settings.leaf_base),
                .coordinator = .{},
            };
        }

        fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn getRoot(self: *const Self) ErrorSet!?RawPageId {
            return self.getStateRoot("root");
        }

        pub fn setRoot(self: *Self, pid: ?RawPageId) ErrorSet!void {
            try self.setStateRoot("root", pid);
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

        pub fn loadLeaf(self: *Self, id: CachePageId) ErrorSet!LeafImpl {
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

        pub fn getFreeLeaf(self: *Self) Error!?LeafImpl {
            const page_id = (try self.getStateRoot("free_leaf_root")) orelse return null;
            var leaf = try self.loadLeaf(page_id);
            errdefer self.deinitLeaf(&leaf);
            if (!try leaf.isInFree() or (try leaf.getPrevFreeLeaf()) != null) {
                return Error.BadData;
            }
            return leaf;
        }

        pub fn addFreeLeaf(self: *Self, leaf: *LeafImpl) Error!void {
            if (try leaf.isInFree()) {
                return;
            }
            const old_root = try self.getStateRoot("free_leaf_root");
            var old_head: ?LeafImpl = null;
            defer if (old_head) |*head| {
                self.deinitLeaf(head);
            };
            if (old_root) |page_id| {
                old_head = try self.loadLeaf(page_id);
                if (!try old_head.?.isInFree() or (try old_head.?.getPrevFreeLeaf()) != null) {
                    return Error.BadData;
                }
            }

            try leaf.setFreeLeafLinks(null, old_root);
            if (old_head) |*head| {
                try head.setPrevFreeLeaf(leaf.id());
            }
            try self.setStateRoot("free_leaf_root", leaf.id());
        }

        pub fn removeFreeLeaf(self: *Self, page_id: RawPageId) Error!void {
            var current = try self.loadLeaf(page_id);
            defer self.deinitLeaf(&current);
            if (!try current.isInFree()) {
                return Error.BadData;
            }

            const prev_id = try current.getPrevFreeLeaf();
            const next_id = try current.getNextFreeLeaf();
            const root = try self.getStateRoot("free_leaf_root");
            if ((prev_id == null and root != page_id) or
                (prev_id != null and root == page_id))
            {
                return Error.BadData;
            }

            var previous: ?LeafImpl = null;
            defer if (previous) |*leaf| {
                self.deinitLeaf(leaf);
            };
            if (prev_id) |id| {
                previous = try self.loadLeaf(id);
                if (!try previous.?.isInFree() or
                    (try previous.?.getNextFreeLeaf()) != page_id)
                {
                    return Error.BadData;
                }
            }

            var next: ?LeafImpl = null;
            defer if (next) |*leaf| {
                self.deinitLeaf(leaf);
            };
            if (next_id) |id| {
                next = try self.loadLeaf(id);
                if (!try next.?.isInFree() or
                    (try next.?.getPrevFreeLeaf()) != page_id)
                {
                    return Error.BadData;
                }
            }

            if (previous) |*leaf| {
                try leaf.setNextFreeLeaf(next_id);
            } else {
                try self.setStateRoot("free_leaf_root", next_id);
            }
            if (next) |*leaf| {
                try leaf.setPrevFreeLeaf(prev_id);
            }
            try current.clearFreeLeaf();
        }

        pub fn isLeaf(self: *const Self, id: CachePageId) ErrorSet!bool {
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

        pub fn loadInode(self: *Self, id: CachePageId) ErrorSet!InodeImpl {
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

        pub fn openValueEditor(self: *Self, leaf: *LeafImpl, key: KeyT) Error!ValueEditorType {
            try self.coordinator.beginValueEditor();
            errdefer self.coordinator.finishValueEditor();
            const value = try leaf.get(key);
            var snapshot = try self.ctx.cache.getTemporaryPage();
            errdefer snapshot.deinit();
            const snapshot_bytes = try snapshot.dataMut();
            @memcpy(snapshot_bytes[0..value.len], value);
            var layout_lock = try leaf.handle.lockLayout();
            errdefer layout_lock.deinit();
            return ValueEditorType.init(
                layout_lock,
                snapshot,
                key,
                value.len,
                &self.coordinator,
            );
        }

        pub fn destroy(self: *Self, page_id: RawPageId) ErrorSet!void {
            try self.ctx.storage_mgr.destroyPage(page_id);
        }

        fn getStateRoot(
            self: *const Self,
            comptime field_name: []const u8,
        ) ErrorSet!?RawPageId {
            var lease = try self.ctx.storage_mgr.state();
            defer lease.deinit();
            const state = try StateView.view(&lease);
            const page_id = @field(state, field_name).get();
            return if (page_id == std.math.maxInt(RawPageId)) null else page_id;
        }

        fn setStateRoot(
            self: *Self,
            comptime field_name: []const u8,
            page_id: ?RawPageId,
        ) ErrorSet!void {
            var lease = try self.ctx.storage_mgr.state();
            defer lease.deinit();
            const state = try StateView.viewMut(&lease);
            @field(state, field_name).set(page_id orelse std.math.maxInt(RawPageId));
            lease.finish();
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
        pub const ValueEditorType = AccessorType.ValueEditorType;
        pub const SplitKeyType = AccessorType.SplitKeyResult;
        pub const KeyInType = KeyT;
        pub const KeyOutType = KeyT;
        pub const ValueInType = []const u8;
        pub const ValueOutType = ValueInType;
        pub const NodeIdType = RawPageId;
        pub const PageId = CachePageId;
        pub const State = StateImpl;
        pub const state_size = @sizeOf(StateImpl);

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

        pub fn structuralMutationCoordinator(self: *Self) *StructuralMutationCoordinator {
            return &self.accessor_state.coordinator;
        }
    };
}
