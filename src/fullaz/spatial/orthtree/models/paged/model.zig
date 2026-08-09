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

pub const Settings = struct {
    max_leaf_entries: usize,
    max_value_size: usize,
    max_tree_depth: usize = 32,
    node_page_kind: u16 = 0,
    entry_page_kind: u16 = 1,
};

pub fn PagedModel(
    comptime PageCacheType: type,
    comptime StorageManager: type,
    comptime CoordT: type,
    comptime dims: usize,
    comptime Endian: std.builtin.Endian,
) type {
    return PagedModelImpl(
        PageCacheType,
        StorageManager,
        CoordT,
        dims,
        traits.PagedEmpty,
        Endian,
    );
}

pub fn PagedModelImpl(
    comptime PageCacheType: type,
    comptime StorageManager: type,
    comptime CoordT: type,
    comptime dims: usize,
    comptime TraitT: fn (comptime type, comptime usize, comptime type) type,
    comptime Endian: std.builtin.Endian,
) type {
    const Value = []const u8;
    const TraitPolicy = TraitT(CoordT, dims, Value);
    const TraitStorage = TraitPolicy.Storage;
    const Pid = PageCacheType.Pid;
    const PageHandle = PageCacheType.Handle;
    const BoxT = geometry.BoundingBox(CoordT, dims);
    const OrthtreePage = orthtree_page.Orthtree(Pid, u16, CoordT, dims, Endian);
    const EntrySlotHeader = OrthtreePage.EntrySlotHeader;
    const entry_slot_header_size = @sizeOf(EntrySlotHeader);
    const MutableView = view_mod.View(Pid, u16, CoordT, dims, TraitStorage, Endian, false).Node;
    const ReadView = view_mod.View(Pid, u16, CoordT, dims, TraitStorage, Endian, true).Node;

    comptime {
        contracts.page_cache.requiresPageCache(PageCacheType);
        orthtree_interfaces.requiresPagedStorageManager(StorageManager);
        if (StorageManager.PageId != Pid) {
            @compileError("Orthtree storage manager PageId must match page cache Pid");
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
        MutableView.Error ||
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
                        .chain = try ChainHandle.init(node.cache, node, .{
                            .chunk_page_kind = node.settings.entry_page_kind,
                        }),
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
                    const data = try temporary.getDataMut();
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
        pub const Id = Pid;
        pub const PageId = Pid;
        pub const Size = u32;
        pub const Box = BoxT;
        pub const Trait = TraitStorage;
        pub const Entries = EntriesWrapperType(Self);
        pub const EntriesMut = EntriesMutWrapperType(Self);

        handle: PageHandle,
        self_id: Pid,
        cache: *PageCacheType,
        storage_manager: *StorageManager,
        settings: Settings,

        fn init(
            handle: PageHandle,
            self_id: Pid,
            cache: *PageCacheType,
            storage_manager: *StorageManager,
            settings: Settings,
        ) Self {
            return .{
                .handle = handle,
                .self_id = self_id,
                .cache = cache,
                .storage_manager = storage_manager,
                .settings = settings,
            };
        }

        fn readView(self: *const Self) Error!ReadView {
            return ReadView.init(try self.handle.getData());
        }

        fn readViewUnchecked(self: *const Self) ReadView {
            return self.readView() catch unreachable;
        }

        fn mutableView(self: *Self) Error!MutableView {
            return MutableView.init(try self.handle.getDataMut());
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

        pub fn getChild(self: *const Self, index: usize) ?Pid {
            return self.readViewUnchecked().getChild(index) catch unreachable;
        }

        pub fn setChild(self: *Self, index: usize, child: Pid) Error!void {
            var view = try self.mutableView();
            try view.setChild(index, child);
        }

        pub fn getParent(self: *const Self) Error!?Pid {
            const view = try self.readView();
            return view.getParent();
        }

        pub fn setParent(self: *Self, parent: ?Pid) Error!void {
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
            return self.getLevel() < self.settings.max_tree_depth;
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
        settings: Settings,
        trait_template: TraitStorage,

        fn init(
            cache: *PageCacheType,
            storage_manager: *StorageManager,
            settings: Settings,
            trait_template: TraitStorage,
        ) Self {
            return .{
                .cache = cache,
                .storage_manager = storage_manager,
                .settings = settings,
                .trait_template = trait_template,
            };
        }

        pub fn getRoot(self: *const Self) ?Pid {
            return self.storage_manager.getRoot();
        }

        pub fn setRoot(self: *Self, root: ?Pid) Error!void {
            try self.storage_manager.setRoot(root);
        }

        pub fn createNode(self: *Self, bounds: BoxT) Error!NodeImpl {
            var handle = try self.cache.create();
            errdefer handle.deinit();
            const page_id = try handle.pid();
            var view = MutableView.init(try handle.getDataMut());
            view.formatPage(self.settings.node_page_kind, page_id, bounds, &self.trait_template);
            return NodeImpl.init(
                try handle.take(),
                page_id,
                self.cache,
                self.storage_manager,
                self.settings,
            );
        }

        pub fn loadNode(self: *Self, page_id: Pid) Error!NodeImpl {
            var handle = try self.cache.fetch(page_id);
            errdefer handle.deinit();
            const view = ReadView.init(try handle.getData());
            if (view.header().kind.get() != self.settings.node_page_kind) {
                return Error.BadType;
            }
            try view.validatePage(page_id);
            if (!TraitPolicy.validate(view.trait())) {
                return Error.BadData;
            }
            return NodeImpl.init(
                try handle.take(),
                page_id,
                self.cache,
                self.storage_manager,
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
        pub const NodeId = Pid;
        pub const Accessor = AccessorImpl;
        pub const Box = BoxT;
        pub const ValueIn = Value;
        pub const ValueOut = Value;
        pub const ValueBorrow = BorrowT;
        pub const Trait = TraitStorage;
        pub const Error = ErrorSet;

        accessor: Accessor,

        pub fn init(cache: *PageCacheType, storage_manager: *StorageManager, settings: Settings) Error!Self {
            var trait_template: Trait = undefined;
            TraitPolicy.format(&trait_template);
            return Self.initWithTrait(cache, storage_manager, settings, trait_template);
        }

        pub fn initWithTrait(
            cache: *PageCacheType,
            storage_manager: *StorageManager,
            settings: Settings,
            trait_template: Trait,
        ) Error!Self {
            if (settings.node_page_kind == settings.entry_page_kind) {
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
                .accessor = Accessor.init(cache, storage_manager, settings, trait_template),
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
