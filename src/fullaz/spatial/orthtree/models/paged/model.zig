const std = @import("std");
const errors = @import("../../../../core/errors.zig");
const contracts = @import("../../../../contracts/contracts.zig");
const contract_interfaces = @import("../../../../contracts/interfaces.zig");
const geometry = @import("../../../geometry.zig");
const orthtree_interfaces = @import("../interfaces.zig");
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
        PageCacheType.Error ||
        StorageManager.Error ||
        MutableView.Error ||
        TraitPolicy.Error ||
        error{ InvalidSettings, ValueTooLarge };

    const NodeImpl = struct {
        const Self = @This();

        pub const Error = ErrorSet;
        pub const Id = Pid;
        pub const Box = BoxT;
        pub const Trait = TraitStorage;

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

        pub fn getTrait(self: *const Self) *const Trait {
            return self.readViewUnchecked().trait();
        }

        pub fn getTraitMut(self: *Self) Error!*Trait {
            var view = try self.mutableView();
            return view.traitMut();
        }
    };

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
        pub const NodeId = Pid;
        pub const Accessor = AccessorImpl;
        pub const Box = BoxT;
        pub const ValueIn = Value;
        pub const ValueOut = Value;
        pub const ValueBorrow = Value;
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
