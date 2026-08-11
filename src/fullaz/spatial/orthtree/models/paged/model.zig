const std = @import("std");
const errors = @import("../../../../core/errors.zig");
const contracts = @import("../../../../contracts/contracts.zig");
const contract_interfaces = @import("../../../../contracts/interfaces.zig");
const geometry = @import("../../../geometry.zig");
const orthtree_page = @import("../../../../page/orthtree.zig");
const orthtree_interfaces = @import("../interfaces.zig");
const slot_chain = @import("../../../../storage/slot_chain/slot_chain.zig");
const traits = @import("../traits.zig");
const view_mod = @import("view.zig");

const requiresErrorDeclaration = contract_interfaces.requiresErrorDeclaration;
const requiresFnSignature = contract_interfaces.requiresFnSignature;
const requiresTypeDeclaration = contract_interfaces.requiresTypeDeclaration;

pub fn Settings(comptime CoordT: type) type {
    return struct {
        max_leaf_entries: usize,
        max_value_size: usize,
        // the max_tree_depth is just a backstop to prevent deep recorsion
        max_tree_depth: usize = 32,
        min_cell_extent: CoordT = 0,
        node_layout_id: u32,
        node_page_kind: u16 = 0,
        entry_page_kind: u16 = 1,
    };
}

pub fn PagedModel(
    comptime PageCacheType: type,
    comptime StorageManager: type,
    comptime FsmT: type,
    comptime CoordT: type,
    comptime dims: usize,
    comptime Endian: std.builtin.Endian,
) type {
    return PagedModelImpl(
        PageCacheType,
        StorageManager,
        FsmT,
        CoordT,
        dims,
        traits.PagedEmpty,
        Endian,
    );
}

pub fn PagedModelImpl(
    comptime PageCacheType: type,
    comptime StorageManager: type,
    comptime FsmT: type,
    comptime CoordT: type,
    comptime dims: usize,
    comptime TraitT: fn (comptime type, comptime usize, comptime type) type,
    comptime Endian: std.builtin.Endian,
) type {
    const Value = []const u8;
    const SettingsT = Settings(CoordT);
    const TraitPolicy = TraitT(CoordT, dims, Value);
    const TraitStorage = TraitPolicy.Storage;
    const Pid = PageCacheType.Pid;
    const PageHandle = PageCacheType.Handle;
    const BoxT = geometry.BoundingBox(CoordT, dims);
    const OrthtreePage = orthtree_page.Orthtree(
        Pid,
        u16,
        CoordT,
        dims,
        Endian,
    );
    const NativeNodeId = OrthtreePage.NodeId;
    const EntrySlotHeader = OrthtreePage.EntrySlotHeader;
    const entry_slot_header_size = @sizeOf(EntrySlotHeader);
    const MutablePackedView = view_mod.PackedView(
        Pid,
        u16,
        CoordT,
        dims,
        TraitStorage,
        Endian,
        false,
    );
    const ReadPackedView = view_mod.PackedView(
        Pid,
        u16,
        CoordT,
        dims,
        TraitStorage,
        Endian,
        true,
    );
    const MutableNodePage = MutablePackedView.NodePage;
    const ReadNodePage = ReadPackedView.NodePage;
    const MutableNodeSlot = MutablePackedView.NodeSlot;
    const ReadNodeSlot = ReadPackedView.NodeSlot;

    comptime {
        contracts.page_cache.requiresPageCache(PageCacheType);
        orthtree_interfaces.requiresPagedStorageManager(StorageManager, NativeNodeId);
        requiresTypeDeclaration(FsmT, "Pid");
        requiresTypeDeclaration(FsmT, "Size");
        requiresErrorDeclaration(FsmT, "Error");
        if (StorageManager.PageId != Pid) {
            @compileError("Orthtree storage manager PageId must match page cache Pid");
        }
        if (FsmT.Pid != Pid) {
            @compileError("Orthtree FSM Pid must match page cache Pid");
        }
        requiresFnSignature(FsmT, "find", fn (*FsmT, FsmT.Size) FsmT.Error!?FsmT.Pid);
        requiresFnSignature(FsmT, "add", fn (*FsmT, FsmT.Pid, FsmT.Size) FsmT.Error!void);
        requiresFnSignature(FsmT, "update", fn (*FsmT, FsmT.Pid, FsmT.Size) FsmT.Error!void);
        requiresFnSignature(FsmT, "remove", fn (*FsmT, FsmT.Pid) FsmT.Error!void);
        if (std.math.cast(FsmT.Size, MutablePackedView.node_slot_size) == null) {
            @compileError("Orthtree FSM Size cannot represent a node slot");
        }

        requiresTypeDeclaration(TraitPolicy, "Storage");
        requiresErrorDeclaration(TraitPolicy, "Error");
        requiresTypeDeclaration(TraitPolicy, "Box");
        requiresTypeDeclaration(TraitPolicy, "Value");
        if (TraitPolicy.Box != BoxT) {
            @compileError("Orthtree trait Box must match the model Box");
        }
        if (TraitPolicy.Value != Value) {
            @compileError("Orthtree paged trait Value must be []const u8");
        }
        if (@alignOf(TraitStorage) != 1) {
            @compileError("Orthtree paged trait storage must have alignment 1");
        }
        requiresFnSignature(TraitPolicy, "format", fn (*TraitStorage) void);
        requiresFnSignature(TraitPolicy, "validate", fn (*const TraitStorage) bool);
        requiresFnSignature(TraitPolicy, "onInsert", fn (*TraitStorage, BoxT, Value) TraitPolicy.Error!void);
        requiresFnSignature(TraitPolicy, "onGrow", fn (*TraitStorage, *const TraitStorage) TraitPolicy.Error!void);
        requiresFnSignature(TraitPolicy, "onAdopt", fn (*TraitStorage, BoxT, Value) TraitPolicy.Error!void);
        requiresFnSignature(TraitPolicy, "onRemove", fn (*TraitStorage, BoxT, Value) TraitPolicy.Error!void);
    }

    const ErrorSet = errors.PageError ||
        errors.SlotsError ||
        errors.IteratorError ||
        PageCacheType.Error ||
        StorageManager.Error ||
        FsmT.Error ||
        MutableNodePage.Error ||
        TraitPolicy.Error ||
        error{ AlreadyInitialized, InvalidSettings, ValueTooLarge };

    const EntryImpl = struct {
        pub const Box = BoxT;
        pub const ValueOut = Value;

        bounds: Box,
        data: Value,

        pub fn box(self: *const @This()) Box {
            return self.bounds;
        }

        pub fn value(self: *const @This()) ValueOut {
            return self.data;
        }
    };

    const encodeEntry = struct {
        fn call(output: []u8, bounds: BoxT, value: Value) ErrorSet!void {
            if (output.len != entry_slot_header_size + value.len) {
                return error.BadData;
            }
            const slot: *EntrySlotHeader = @ptrCast(@alignCast(&output[0]));
            inline for (0..dims) |axis| {
                slot.bounds.low[axis].set(bounds.low[axis]);
                slot.bounds.high[axis].set(bounds.high[axis]);
            }
            @memcpy(output[entry_slot_header_size..], value);
        }
    }.call;

    const decodeEntry = struct {
        fn call(input: []const u8) ErrorSet!EntryImpl {
            if (input.len < entry_slot_header_size) {
                return error.BadData;
            }
            const slot: *const EntrySlotHeader = @ptrCast(@alignCast(&input[0]));
            var bounds = BoxT.init();
            inline for (0..dims) |axis| {
                bounds.low[axis] = slot.bounds.low[axis].get();
                bounds.high[axis] = slot.bounds.high[axis].get();
            }
            return .{
                .bounds = bounds,
                .data = input[entry_slot_header_size..],
            };
        }
    }.call;

    const EntryChainHandle = struct {
        fn call(comptime NodeT: type) type {
            const Handle = slot_chain.HandleImpl(
                PageCacheType,
                NodeT,
                void,
                void,
                void,
                Endian,
            );
            return Handle;
        }
    }.call;

    const ValueBorrowType = struct {
        fn call(comptime NodeT: type) type {
            const ChainHandle = EntryChainHandle(NodeT);

            return struct {
                pending: ChainHandle.PendingRemoval,
                value: Value,
            };
        }
    }.call;

    const EntriesWrapperType = struct {
        fn call(comptime NodeT: type) type {
            const ChainHandle = EntryChainHandle(NodeT);

            return struct {
                const Self = @This();

                pub const Iterator = struct {
                    const IteratorSelf = @This();

                    iterator: ?ChainHandle.Iterator,

                    fn init(chain: *ChainHandle) ErrorSet!IteratorSelf {
                        return .{ .iterator = try chain.iterator() };
                    }

                    pub fn next(self: *IteratorSelf) ErrorSet!?EntryImpl {
                        if (self.iterator) |*chain_iterator| {
                            const result = try chain_iterator.next() orelse return null;
                            return try decodeEntry(result.value);
                        }
                        return null;
                    }

                    pub fn deinit(self: *IteratorSelf) void {
                        if (self.iterator) |*chain_iterator| {
                            chain_iterator.deinit();
                        }
                        self.iterator = null;
                    }
                };

                chain: ChainHandle,

                pub fn init(node: *NodeT) ErrorSet!Self {
                    return .{
                        .chain = try ChainHandle.init(node.cache, node, .{
                            .chunk_page_kind = node.settings.entry_page_kind,
                        }),
                    };
                }

                pub fn iterator(self: *Self) ErrorSet!Iterator {
                    return try Iterator.init(&self.chain);
                }

                pub fn deinit(self: *Self) void {
                    self.chain.deinit();
                }
            };
        }
    }.call;

    const EntriesMutWrapperType = struct {
        fn call(comptime NodeT: type) type {
            const ChainHandle = EntryChainHandle(NodeT);
            const ValueBorrowT = ValueBorrowType(NodeT);

            return struct {
                const Self = @This();

                pub const Cursor = struct {
                    const CursorSelf = @This();

                    entries: *Self,
                    iterator: ?ChainHandle.Iterator,
                    dirty_page: ?Pid = null,
                    current: ?EntryImpl = null,

                    fn init(entries: *Self) ErrorSet!CursorSelf {
                        return .{
                            .entries = entries,
                            .iterator = try entries.chain.iterator(),
                        };
                    }

                    fn cleanDirtyPage(self: *CursorSelf) ErrorSet!void {
                        const page_id = self.dirty_page orelse return;
                        var page = try self.entries.chain.loadPage(page_id);
                        defer page.deinit();
                        const removed = try page.removeTombstones();
                        if (removed > 0) {
                            const total = try self.entries.node.getTotalSize();
                            if (removed > @as(usize, @intCast(total))) {
                                return error.BadData;
                            }
                            try self.entries.node.setTotalSize(total - @as(u32, @intCast(removed)));
                        }
                        self.dirty_page = null;
                    }

                    pub fn next(self: *CursorSelf) ErrorSet!?EntryImpl {
                        if (self.iterator) |*iterator| {
                            const result = try iterator.next();
                            if (result) |entry_result| {
                                if (self.dirty_page) |page_id| {
                                    if (page_id != entry_result.page_id) {
                                        try self.cleanDirtyPage();
                                    }
                                }
                                const entry = try decodeEntry(entry_result.value);
                                self.current = entry;
                                return entry;
                            }
                            try self.cleanDirtyPage();
                            self.current = null;
                            return null;
                        }
                        return null;
                    }

                    pub fn deinit(self: *CursorSelf) void {
                        self.cleanDirtyPage() catch {};
                        if (self.iterator) |*iterator| {
                            iterator.deinit();
                        }
                        self.iterator = null;
                        self.current = null;
                    }
                };

                node: *NodeT,
                chain: ChainHandle,

                pub fn init(node: *NodeT) ErrorSet!Self {
                    return .{
                        .node = node,
                        .chain = try ChainHandle.init(
                            node.cache,
                            node,
                            .{
                                .chunk_page_kind = node.settings.entry_page_kind,
                            },
                        ),
                    };
                }

                pub fn appendEntry(self: *Self, bounds: BoxT, value: Value) ErrorSet!void {
                    if (value.len > self.node.settings.max_value_size) {
                        return error.ValueTooLarge;
                    }
                    var buffer: [entry_slot_header_size]u8 = undefined;
                    if (value.len == 0) {
                        try encodeEntry(&buffer, bounds, value);
                        _ = try self.chain.append(&buffer);
                        return;
                    }
                    var temporary = try self.node.cache.getTemporaryPage();
                    defer temporary.deinit();
                    const data = try temporary.dataMut();
                    const entry_len = entry_slot_header_size + value.len;
                    if (entry_len > data.len) {
                        return error.ValueTooLarge;
                    }
                    try encodeEntry(data[0..entry_len], bounds, value);
                    _ = try self.chain.append(data[0..entry_len]);
                }

                pub fn cursor(self: *Self) ErrorSet!Cursor {
                    return try Cursor.init(self);
                }

                pub fn moveCurrentTo(self: *Self, entry_cursor: *Cursor, target: *Self) ErrorSet!EntryImpl {
                    _ = self;
                    const entry = entry_cursor.current orelse return error.OutOfBounds;
                    try target.appendEntry(entry.box(), entry.value());
                    if (entry_cursor.iterator) |*iterator| {
                        var pending = try iterator.markForRemoval();
                        defer pending.deinit();
                        if (entry_cursor.dirty_page) |page_id| {
                            if (page_id != pending.page_id) {
                                return error.BadData;
                            }
                        } else {
                            entry_cursor.dirty_page = pending.page_id;
                        }
                        entry_cursor.current = null;
                        return entry;
                    }
                    return error.OutOfBounds;
                }

                pub fn removeCurrent(self: *Self, entry_cursor: *Cursor) ErrorSet!ValueBorrowT {
                    _ = self;
                    if (entry_cursor.iterator) |*iterator| {
                        var pending = try iterator.markForRemoval();
                        errdefer pending.deinit();
                        const entry = try decodeEntry(try pending.value());
                        entry_cursor.current = null;
                        return .{
                            .pending = pending,
                            .value = entry.value(),
                        };
                    }
                    return error.OutOfBounds;
                }

                pub fn deinit(self: *Self) void {
                    self.chain.deinit();
                }
            };
        }
    }.call;

    const NodeImpl = struct {
        const Self = @This();

        pub const Error = ErrorSet;
        pub const Id = NativeNodeId;
        pub const PageId = Pid;
        pub const Size = u32;
        pub const Box = BoxT;
        pub const Trait = TraitStorage;
        pub const Entries = EntriesWrapperType(Self);
        pub const EntriesMut = EntriesMutWrapperType(Self);

        handle: PageHandle,
        self_id: NativeNodeId,
        cache: *PageCacheType,
        storage_manager: *StorageManager,
        fsm: *FsmT,
        settings: SettingsT,

        fn init(
            handle: PageHandle,
            self_id: NativeNodeId,
            cache: *PageCacheType,
            storage_manager: *StorageManager,
            fsm: *FsmT,
            settings: SettingsT,
        ) Self {
            return .{
                .handle = handle,
                .self_id = self_id,
                .cache = cache,
                .storage_manager = storage_manager,
                .fsm = fsm,
                .settings = settings,
            };
        }

        fn readView(self: *const Self) Error!ReadNodeSlot {
            const page = ReadNodePage.init(try self.handle.data());
            try page.validatePage(self.self_id.page_id, self.settings.node_page_kind, self.settings.node_layout_id);
            const slot = try page.slot(self.self_id.slot_id);
            try slot.validate();
            return slot;
        }

        fn readViewUnchecked(self: *const Self) ReadNodeSlot {
            return self.readView() catch unreachable;
        }

        fn mutableView(self: *Self) Error!MutableNodeSlot {
            var page = MutableNodePage.init(try self.handle.dataMut());
            try page.validatePage(self.self_id.page_id, self.settings.node_page_kind, self.settings.node_layout_id);
            return try page.slotMut(self.self_id.slot_id);
        }

        pub fn deinit(self: *Self) void {
            self.handle.deinit();
        }

        pub fn id(self: *const Self) Id {
            return self.self_id;
        }

        pub fn size(self: *const Self) usize {
            return self.readViewUnchecked().entryChain().count;
        }

        pub fn isLeaf(self: *const Self) bool {
            return self.readViewUnchecked().isLeaf();
        }

        pub fn bounds(self: *const Self) Box {
            return self.readViewUnchecked().bounds();
        }

        pub fn getChild(self: *const Self, index: usize) ?NativeNodeId {
            return self.readViewUnchecked().getChild(index) catch unreachable;
        }

        pub fn setChild(self: *Self, index: usize, child: NativeNodeId) Error!void {
            var view = try self.mutableView();
            try view.setChild(index, child);
        }

        pub fn getParent(self: *const Self) Error!?NativeNodeId {
            const view = try self.readView();
            return view.getParent();
        }

        pub fn setParent(self: *Self, parent: ?NativeNodeId) Error!void {
            var view = try self.mutableView();
            view.setParent(parent);
        }

        pub fn getFirst(self: *const Self) Error!?Pid {
            const view = try self.readView();
            return view.entryChain().first;
        }

        pub fn setFirst(self: *Self, first: ?Pid) Error!void {
            var view = try self.mutableView();
            const chain = view.entryChain();
            try view.setEntryChainUnchecked(first, chain.last, chain.count);
        }

        pub fn getLast(self: *const Self) Error!?Pid {
            const view = try self.readView();
            return view.entryChain().last;
        }

        pub fn setLast(self: *Self, last: ?Pid) Error!void {
            var view = try self.mutableView();
            const chain = view.entryChain();
            try view.setEntryChainUnchecked(chain.first, last, chain.count);
        }

        pub fn getTotalSize(self: *const Self) Error!Size {
            const count = self.readViewUnchecked().entryChain().count;
            return std.math.cast(Size, count) orelse Error.BadData;
        }

        pub fn setTotalSize(self: *Self, count: Size) Error!void {
            var view = try self.mutableView();
            const chain = view.entryChain();
            try view.setEntryChainUnchecked(chain.first, chain.last, count);
        }

        pub fn destroyPage(self: *Self, page_id: Pid) Error!void {
            try self.storage_manager.destroyPage(page_id);
        }

        pub fn getLevel(self: *const Self) usize {
            return self.readViewUnchecked().getLevel();
        }

        pub fn setLevel(self: *Self, level: usize) Error!void {
            var view = try self.mutableView();
            try view.setLevel(level);
        }

        pub fn canInsertEntry(self: *const Self, _: Box, value: Value) Error!bool {
            if (value.len > self.settings.max_value_size) {
                return Error.ValueTooLarge;
            }
            return self.size() < self.settings.max_leaf_entries;
        }

        pub fn canSplit(self: *const Self) bool {
            if (self.getLevel() >= self.settings.max_tree_depth) {
                return false;
            }
            return self.bounds().splittable(self.settings.min_cell_extent);
        }

        pub fn beforeSplit(self: *Self) Error!void {
            var view = try self.mutableView();
            view.setInternal();
        }

        pub fn addEntry(self: *Self, node_bounds: Box, value: Value) Error!void {
            var entry_storage = try EntriesMut.init(self);
            defer entry_storage.deinit();
            try entry_storage.appendEntry(node_bounds, value);
        }

        pub fn entries(self: *Self) Error!Entries {
            return try Entries.init(self);
        }

        pub fn entriesMut(self: *Self) Error!EntriesMut {
            return try EntriesMut.init(self);
        }

        pub fn getTrait(self: *const Self) *const Trait {
            return self.readViewUnchecked().trait();
        }

        pub fn getTraitMut(self: *Self) Error!*Trait {
            var view = try self.mutableView();
            return view.traitMut();
        }
    };

    const BorrowT = ValueBorrowType(NodeImpl);

    const AccessorImpl = struct {
        const Self = @This();

        pub const Error = ErrorSet;

        cache: *PageCacheType,
        storage_manager: *StorageManager,
        fsm: *FsmT,
        settings: SettingsT,
        trait_template: TraitStorage,

        fn init(
            cache: *PageCacheType,
            storage_manager: *StorageManager,
            fsm: *FsmT,
            settings: SettingsT,
            trait_template: TraitStorage,
        ) Self {
            return .{
                .cache = cache,
                .storage_manager = storage_manager,
                .fsm = fsm,
                .settings = settings,
                .trait_template = trait_template,
            };
        }

        pub fn getRoot(self: *const Self) ?NativeNodeId {
            return self.storage_manager.getRoot();
        }

        pub fn setRoot(self: *Self, root: ?NativeNodeId) Error!void {
            try self.storage_manager.setRoot(root);
        }

        fn fsmSize(_: *const Self, slots_count: usize) Error!FsmT.Size {
            const bytes = std.math.mul(usize, slots_count, MutablePackedView.node_slot_size) catch return Error.BadData;
            return std.math.cast(FsmT.Size, bytes) orelse Error.BadData;
        }

        pub fn createNode(self: *Self, bounds: BoxT) Error!NodeImpl {
            const required_size = try self.fsmSize(1);
            const found_page = try self.fsm.find(required_size);
            var handle = if (found_page) |page_id|
                try self.cache.fetch(page_id)
            else
                try self.cache.create();
            errdefer handle.deinit();
            const page_id = try handle.pid();
            var page = MutableNodePage.init(try handle.dataMut());
            const is_new = found_page == null;
            if (is_new) {
                try page.formatPage(self.settings.node_page_kind, page_id, self.settings.node_layout_id);
            } else {
                try page.validatePage(page_id, self.settings.node_page_kind, self.settings.node_layout_id);
            }
            const slot_id = try page.allocateSlot() orelse return Error.BadData;
            var slot = try page.slotMut(slot_id);
            slot.formatSlot(bounds, &self.trait_template);
            const free_size = try self.fsmSize(try page.freeSlots());
            if (is_new) {
                try self.fsm.add(page_id, free_size);
            } else {
                try self.fsm.update(page_id, free_size);
            }
            return NodeImpl.init(
                try handle.take(),
                .{ .page_id = page_id, .slot_id = @intCast(slot_id) },
                self.cache,
                self.storage_manager,
                self.fsm,
                self.settings,
            );
        }

        pub fn loadNode(self: *Self, node_id: NativeNodeId) Error!NodeImpl {
            var handle = try self.cache.fetch(node_id.page_id);
            errdefer handle.deinit();
            const page = ReadNodePage.init(try handle.data());
            try page.validatePage(node_id.page_id, self.settings.node_page_kind, self.settings.node_layout_id);
            const slot = try page.slot(node_id.slot_id);
            try slot.validate();
            if (!TraitPolicy.validate(slot.trait())) {
                return Error.BadData;
            }
            return NodeImpl.init(
                try handle.take(),
                node_id,
                self.cache,
                self.storage_manager,
                self.fsm,
                self.settings,
            );
        }

        pub fn deinitNode(_: *Self, node: *NodeImpl) void {
            node.deinit();
        }
    };

    return struct {
        const Self = @This();

        pub const Node = NodeImpl;
        pub const Entry = EntryImpl;
        pub const NodeId = NativeNodeId;
        pub const Accessor = AccessorImpl;
        pub const Box = BoxT;
        pub const ValueIn = Value;
        pub const ValueOut = Value;
        pub const ValueBorrow = BorrowT;
        pub const Trait = TraitStorage;
        pub const Error = ErrorSet;
        pub const Settings = SettingsT;

        accessor: Accessor,

        pub fn init(cache: *PageCacheType, storage_manager: *StorageManager, fsm: *FsmT, settings: SettingsT) Error!Self {
            var trait_template: Trait = undefined;
            TraitPolicy.format(&trait_template);
            return Self.initWithTrait(cache, storage_manager, fsm, settings, trait_template);
        }

        pub fn initWithTrait(
            cache: *PageCacheType,
            storage_manager: *StorageManager,
            fsm: *FsmT,
            settings: SettingsT,
            trait_template: Trait,
        ) Error!Self {
            if (settings.node_page_kind == settings.entry_page_kind) {
                return Error.InvalidSettings;
            }
            const minimum_node_page_size = @sizeOf(MutableNodePage.PageHeader) +
                @sizeOf(OrthtreePage.NodePageSubheader) +
                (2 * @sizeOf(u64)) +
                MutablePackedView.node_slot_size;
            if (cache.pageSize() < minimum_node_page_size) {
                return Error.InvalidSettings;
            }
            if (settings.max_leaf_entries == 0) {
                return Error.InvalidSettings;
            }
            if (settings.max_tree_depth > std.math.maxInt(u8)) {
                return Error.InvalidSettings;
            }
            if (!TraitPolicy.validate(&trait_template)) {
                return Error.BadData;
            }
            return .{
                .accessor = Accessor.init(cache, storage_manager, fsm, settings, trait_template),
            };
        }

        pub fn deinit(_: *Self) void {}

        pub fn getAccessor(self: *Self) *Accessor {
            return &self.accessor;
        }

        pub fn incrementEntriesCount(self: *Self) Error!void {
            const count = try self.accessor.storage_manager.getEntriesCount();
            const next = std.math.add(usize, count, 1) catch return Error.BadData;
            try self.accessor.storage_manager.setEntriesCount(next);
        }

        pub fn decrementEntriesCount(self: *Self) Error!void {
            const count = try self.accessor.storage_manager.getEntriesCount();
            const next = std.math.sub(usize, count, 1) catch return Error.BadData;
            try self.accessor.storage_manager.setEntriesCount(next);
        }

        pub fn getEntriesCount(self: *const Self) Error!usize {
            return self.accessor.storage_manager.getEntriesCount();
        }

        pub fn valueOutAsIn(_: *const Self, value: ValueOut) ValueIn {
            return value;
        }

        pub fn valueBorrowAsIn(_: *const Self, value: *const ValueBorrow) ValueIn {
            return value.value;
        }

        pub fn finalizeBorrowValue(_: *Self, value: *ValueBorrow) Error!void {
            if (!try value.pending.clean()) {
                return Error.BadData;
            }
        }

        pub fn deinitBorrowValue(_: *Self, value: *ValueBorrow) void {
            value.pending.deinit();
        }

        pub fn onInsert(self: *Self, node: *Node, bounds: Box, value: ValueIn) Error!void {
            _ = self;
            try TraitPolicy.onInsert(try node.getTraitMut(), bounds, value);
        }

        pub fn onGrow(self: *Self, node: *Node, new_root: *Node) Error!void {
            _ = self;
            try TraitPolicy.onGrow(try new_root.getTraitMut(), node.getTrait());
        }

        pub fn onAdopt(self: *Self, _: *Node, target: *Node, bounds: Box, value: ValueIn) Error!void {
            _ = self;
            try TraitPolicy.onAdopt(try target.getTraitMut(), bounds, value);
        }

        pub fn onRemove(self: *Self, node: *Node, bounds: Box, value: ValueIn) Error!void {
            _ = self;
            try TraitPolicy.onRemove(try node.getTraitMut(), bounds, value);
        }
    };
}
