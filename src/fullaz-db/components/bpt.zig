const std = @import("std");
const component = @import("../component/component.zig");
const managers = @import("../component/managers/managers.zig");
const interfaces = @import("fullaz").contracts.interfaces;
const PackedInt = @import("fullaz").core.packed_int.PackedInt;
const dynamic_metadata = @import("../file/metadata/dynamic.zig");
const tagged = @import("../file/tagged_fields.zig");
const low_level_bpt = @import("fullaz").bpt;
const gc = @import("fullaz").gc;
const FingerprintWriter = @import("../component/fingerprint.zig").Writer;

fn requireOption(comptime OptionsT: type, comptime name: []const u8) void {
    if (!@hasField(OptionsT, name)) {
        @compileError("Missing fullaz-db.bpt option: " ++ name);
    }
}

fn unsignedOption(
    comptime value: anytype,
    comptime T: type,
    comptime diagnostic: []const u8,
) T {
    switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => {},
        else => @compileError(diagnostic),
    }
    return std.math.cast(T, value) orelse @compileError(diagnostic);
}

fn isKnownOption(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "compare") or
        std.mem.eql(u8, name, "CompareContext") or
        std.mem.eql(u8, name, "comparator_id") or
        std.mem.eql(u8, name, "maximum_key_size") or
        std.mem.eql(u8, name, "maximum_value_size") or
        std.mem.eql(u8, name, "fixed_value_size") or
        std.mem.eql(u8, name, "rebalance_policy") or
        std.mem.eql(u8, name, "format_version");
}

pub fn bpt(comptime options: anytype) component.Descriptor {
    @setEvalBranchQuota(20_000); // extend the branch quota for this function

    const OptionsT = @TypeOf(options);
    const options_info = @typeInfo(OptionsT);

    if (options_info != .@"struct" or options_info.@"struct".is_tuple) {
        @compileError("fullaz-db.bpt options must be a named struct");
    }

    inline for (options_info.@"struct".fields) |field| {
        if (comptime !isKnownOption(field.name)) {
            @compileError("Unknown fullaz-db.bpt option: " ++ field.name);
        }
    }
    requireOption(OptionsT, "compare");
    requireOption(OptionsT, "CompareContext");
    requireOption(OptionsT, "comparator_id");
    requireOption(OptionsT, "maximum_key_size");
    requireOption(OptionsT, "maximum_value_size");

    if (@TypeOf(options.CompareContext) != type) {
        @compileError("fullaz-db.bpt CompareContext must be a type");
    }
    const CompareContextT = options.CompareContext;
    const CompareFn = fn (CompareContextT, []const u8, []const u8) std.math.Order;
    if (@TypeOf(options.compare) != CompareFn) {
        @compileError("fullaz-db.bpt compare has an invalid signature");
    }

    const configured_comparator_id = unsignedOption(
        options.comparator_id,
        u32,
        "fullaz-db.bpt comparator_id must fit u32",
    );
    if (configured_comparator_id == 0) {
        @compileError("fullaz-db.bpt comparator_id cannot be zero");
    }
    const configured_maximum_key_size = unsignedOption(
        options.maximum_key_size,
        usize,
        "fullaz-db.bpt maximum_key_size must fit usize",
    );
    const configured_maximum_value_size = unsignedOption(
        options.maximum_value_size,
        usize,
        "fullaz-db.bpt maximum_value_size must fit usize",
    );
    const configured_fixed_value_size: ?usize = if (@hasField(OptionsT, "fixed_value_size"))
        unsignedOption(
            options.fixed_value_size,
            usize,
            "fullaz-db.bpt fixed_value_size must fit usize",
        )
    else
        null;
    if (configured_fixed_value_size) |fixed_value_size| {
        if (fixed_value_size > configured_maximum_value_size) {
            @compileError("fullaz-db.bpt fixed_value_size cannot exceed maximum_value_size");
        }
    }

    const configured_format_version = if (@hasField(OptionsT, "format_version"))
        unsignedOption(
            options.format_version,
            u32,
            "fullaz-db.bpt format_version must fit u32",
        )
    else
        1;

    if (configured_format_version == 0) {
        @compileError("fullaz-db.bpt format_version cannot be zero");
    }
    if (@hasField(OptionsT, "rebalance_policy")) {
        const PolicyT = @TypeOf(options.rebalance_policy);
        if (PolicyT != @TypeOf(.neighbor_share) and PolicyT != low_level_bpt.RebalancePolicy) {
            @compileError("fullaz-db.bpt rebalance_policy has an invalid type");
        }
    }
    const configured_rebalance_policy: low_level_bpt.RebalancePolicy = if (@hasField(
        OptionsT,
        "rebalance_policy",
    )) options.rebalance_policy else .neighbor_share;
    const configured_compare = options.compare;

    const Trait = struct {
        pub const kind_name: []const u8 = "fullaz.bpt.paged";
        pub const format_version: u32 = configured_format_version;
        pub const page_kind_count: usize = 2;
        pub const page_roles: [page_kind_count][]const u8 = .{ "leaf", "inode" };
        pub const comparator_id: u32 = configured_comparator_id;
        pub const CompareContext = CompareContextT;
        pub const compare = configured_compare;
        pub const maximum_key_size: usize = configured_maximum_key_size;
        pub const maximum_value_size: usize = configured_maximum_value_size;
        pub const fixed_value_size: ?usize = configured_fixed_value_size;
        pub const rebalance_policy = configured_rebalance_policy;

        pub fn fingerprint(writer: *FingerprintWriter) void {
            writer.writeInt(u32, comparator_id);
            writer.writeInt(u64, @intCast(maximum_key_size));
            writer.writeInt(u64, @intCast(maximum_value_size));
            writer.writeInt(u64, fixed_value_size orelse 0);
            writer.writeBytes(@tagName(rebalance_policy));
        }

        pub fn Binding(comptime BackendT: type) type {
            interfaces.requiresFnSignature(
                BackendT,
                "allocator",
                fn (*const BackendT) std.mem.Allocator,
            );
            const ManagerT = managers.SingleRootManager(BackendT);
            comptime low_level_bpt.models.interfaces.requiresStorageManager(ManagerT);
            const CacheT = BackendT.CacheType;
            const ModelT = low_level_bpt.models.PagedModel(
                CacheT,
                ManagerT,
                configured_compare,
                CompareContextT,
            );
            const TreeT = low_level_bpt.Bpt(ModelT);
            const ReadIteratorT = struct {
                const Self = @This();
                const Inner = TreeT.Iterator;
                const GetReturn = @typeInfo(@TypeOf(Inner.get)).@"fn".return_type.?;
                const NextReturn = @typeInfo(@TypeOf(Inner.next)).@"fn".return_type.?;
                const PrevReturn = @typeInfo(@TypeOf(Inner.prev)).@"fn".return_type.?;

                iterator_ptr: *align(@alignOf(Inner)) anyopaque,
                allocator_value: std.mem.Allocator,

                fn wrap(
                    allocator_value: std.mem.Allocator,
                    inner_optional: ?Inner,
                ) std.mem.Allocator.Error!?Self {
                    if (inner_optional) |inner_value| {
                        var owned = inner_value;
                        const ptr = allocator_value.create(Inner) catch |err| {
                            owned.deinit();
                            return err;
                        };
                        ptr.* = owned;
                        return .{
                            .iterator_ptr = ptr,
                            .allocator_value = allocator_value,
                        };
                    }
                    return null;
                }

                fn inner(self: *const Self) *Inner {
                    return @ptrCast(self.iterator_ptr);
                }

                pub fn get(self: *const Self) GetReturn {
                    return self.inner().get();
                }

                pub fn next(self: *Self) NextReturn {
                    return self.inner().next();
                }

                pub fn prev(self: *Self) PrevReturn {
                    return self.inner().prev();
                }

                pub fn deinit(self: *Self) void {
                    const ptr = self.inner();
                    ptr.deinit();
                    self.allocator_value.destroy(ptr);
                    self.* = undefined;
                }
            };
            const MutableProxyT = struct {
                const Self = @This();

                pub const Error = TreeT.Error || CacheT.Error;
                pub const ConstIterator = ReadIteratorT;

                pub const ValueEditor = struct {
                    const EditorSelf = @This();

                    editor: TreeT.ValueEditor,
                    cache_ptr: *align(@alignOf(CacheT)) anyopaque,
                    active_editor: *bool,
                    transaction_generation: ?u64,

                    fn cache(self: *const EditorSelf) *CacheT {
                        return @ptrCast(self.cache_ptr);
                    }

                    fn requireTransaction(self: *const EditorSelf) Error!void {
                        if (self.transaction_generation == null or
                            self.cache().transactionGeneration() != self.transaction_generation)
                        {
                            return Error.TransactionInactive;
                        }
                    }

                    pub fn valueMut(self: *EditorSelf) Error![]u8 {
                        try self.requireTransaction();
                        return self.editor.valueMut();
                    }

                    pub fn finish(self: *EditorSelf) Error!void {
                        try self.requireTransaction();
                        self.editor.finish() catch |err| {
                            switch (err) {
                                error.ValueEditorActive,
                                error.StructuralMutationActive,
                                error.StaleIterator,
                                error.EditorInvalidated,
                                => return err,
                                else => self.cache().markTransactionFailed(),
                            }
                            return err;
                        };
                        self.active_editor.* = false;
                    }

                    pub fn deinit(self: *EditorSelf) void {
                        self.editor.deinit();
                        self.active_editor.* = false;
                    }
                };

                pub const MutableIterator = struct {
                    const IteratorSelf = @This();
                    const GetPayload = @typeInfo(ReadIteratorT.GetReturn).error_union.payload;

                    inner_value: ReadIteratorT,
                    cache_ptr: *align(@alignOf(CacheT)) anyopaque,
                    active_editor: *bool,
                    transaction_generation: ?u64,

                    fn cache(self: *const IteratorSelf) *CacheT {
                        return @ptrCast(self.cache_ptr);
                    }

                    fn requireTransaction(self: *const IteratorSelf) Error!void {
                        if (self.transaction_generation == null or
                            self.cache().transactionGeneration() != self.transaction_generation)
                        {
                            return Error.TransactionInactive;
                        }
                    }

                    fn wrap(
                        allocator_value: std.mem.Allocator,
                        inner_optional: ?TreeT.Iterator,
                        cache_ptr: *align(@alignOf(CacheT)) anyopaque,
                        active_editor: *bool,
                        transaction_generation: ?u64,
                    ) std.mem.Allocator.Error!?IteratorSelf {
                        const inner_value = try ReadIteratorT.wrap(allocator_value, inner_optional);
                        if (inner_value) |iterator_value| {
                            return .{
                                .inner_value = iterator_value,
                                .cache_ptr = cache_ptr,
                                .active_editor = active_editor,
                                .transaction_generation = transaction_generation,
                            };
                        }
                        return null;
                    }

                    pub fn get(self: *const IteratorSelf) Error!GetPayload {
                        try self.requireTransaction();
                        return self.inner_value.get();
                    }

                    pub fn next(self: *IteratorSelf) Error!GetPayload {
                        try self.requireTransaction();
                        return self.inner_value.next();
                    }

                    pub fn prev(self: *IteratorSelf) Error!GetPayload {
                        try self.requireTransaction();
                        return self.inner_value.prev();
                    }

                    pub fn editValue(self: *IteratorSelf) Error!?ValueEditor {
                        try self.requireTransaction();
                        if (self.active_editor.*) {
                            return error.ValueEditorActive;
                        }
                        const inner_editor = try self.inner_value.inner().editValue();
                        if (inner_editor) |editor| {
                            self.active_editor.* = true;
                            return .{
                                .editor = editor,
                                .cache_ptr = self.cache_ptr,
                                .active_editor = self.active_editor,
                                .transaction_generation = self.transaction_generation,
                            };
                        }
                        return null;
                    }

                    pub fn deinit(self: *IteratorSelf) void {
                        self.inner_value.deinit();
                    }
                };

                pub const Iterator = MutableIterator;

                tree_ptr: *align(@alignOf(TreeT)) anyopaque,
                cache_ptr: *align(@alignOf(CacheT)) anyopaque,
                allocator_value: std.mem.Allocator,
                transaction_generation: ?u64,
                active_editor: *bool,

                fn init(
                    tree_value: *TreeT,
                    cache_value: *CacheT,
                    allocator_value: std.mem.Allocator,
                    active_editor: *bool,
                ) Self {
                    return .{
                        .tree_ptr = tree_value,
                        .cache_ptr = cache_value,
                        .allocator_value = allocator_value,
                        .transaction_generation = cache_value.transactionGeneration(),
                        .active_editor = active_editor,
                    };
                }

                fn tree(self: *const Self) *TreeT {
                    return @ptrCast(self.tree_ptr);
                }

                fn cache(self: *const Self) *CacheT {
                    return @ptrCast(self.cache_ptr);
                }

                fn requireTransaction(self: *const Self) Error!void {
                    if (self.transaction_generation == null or
                        self.cache().transactionGeneration() != self.transaction_generation)
                    {
                        return Error.TransactionInactive;
                    }
                }

                pub fn iterator(self: *const Self) Error!?Iterator {
                    try self.requireTransaction();
                    return MutableIterator.wrap(
                        self.allocator_value,
                        try self.tree().iterator(),
                        self.cache_ptr,
                        self.active_editor,
                        self.transaction_generation,
                    );
                }

                pub fn iteratorFromEnd(self: *const Self) Error!?Iterator {
                    try self.requireTransaction();
                    return MutableIterator.wrap(
                        self.allocator_value,
                        try self.tree().iteratorFromEnd(),
                        self.cache_ptr,
                        self.active_editor,
                        self.transaction_generation,
                    );
                }

                pub fn find(self: *const Self, key: ModelT.KeyLikeType) Error!?Iterator {
                    try self.requireTransaction();
                    return MutableIterator.wrap(
                        self.allocator_value,
                        try self.tree().find(key),
                        self.cache_ptr,
                        self.active_editor,
                        self.transaction_generation,
                    );
                }

                pub fn lowerBound(self: *const Self, key: ModelT.KeyLikeType) Error!?Iterator {
                    try self.requireTransaction();
                    return MutableIterator.wrap(
                        self.allocator_value,
                        try self.tree().lowerBound(key),
                        self.cache_ptr,
                        self.active_editor,
                        self.transaction_generation,
                    );
                }

                pub fn openValueEditor(
                    self: *const Self,
                    key: ModelT.KeyLikeType,
                ) Error!?ValueEditor {
                    try self.requireTransaction();
                    if (self.active_editor.*) {
                        return error.ValueEditorActive;
                    }
                    const inner_editor = try self.tree().openValueEditor(key);
                    if (inner_editor) |editor| {
                        self.active_editor.* = true;
                        return .{
                            .editor = editor,
                            .cache_ptr = self.cache_ptr,
                            .active_editor = self.active_editor,
                            .transaction_generation = self.transaction_generation,
                        };
                    }
                    return null;
                }

                pub fn insert(
                    self: *const Self,
                    key: ModelT.KeyLikeType,
                    value: ModelT.ValueInType,
                ) Error!bool {
                    try self.requireTransaction();
                    return self.tree().insert(key, value) catch |err| {
                        self.cache().markTransactionFailed();
                        return err;
                    };
                }

                pub fn update(
                    self: *const Self,
                    key: ModelT.KeyLikeType,
                    value: ModelT.ValueInType,
                ) Error!bool {
                    try self.requireTransaction();
                    return self.tree().update(key, value) catch |err| {
                        self.cache().markTransactionFailed();
                        return err;
                    };
                }

                pub fn remove(self: *const Self, key: ModelT.KeyLikeType) Error!bool {
                    try self.requireTransaction();
                    return self.tree().remove(key) catch |err| {
                        self.cache().markTransactionFailed();
                        return err;
                    };
                }
            };
            const ConstProxyT = struct {
                const Self = @This();

                pub const Error = TreeT.Error;
                pub const ConstIterator = ReadIteratorT;
                pub const Iterator = ConstIterator;

                tree_ptr: *align(@alignOf(TreeT)) const anyopaque,
                allocator_value: std.mem.Allocator,

                fn init(
                    tree_value: *const TreeT,
                    allocator_value: std.mem.Allocator,
                ) Self {
                    return .{
                        .tree_ptr = tree_value,
                        .allocator_value = allocator_value,
                    };
                }

                fn tree(self: *const Self) *const TreeT {
                    return @ptrCast(self.tree_ptr);
                }

                pub fn iterator(self: *const Self) Error!?Iterator {
                    return ReadIteratorT.wrap(
                        self.allocator_value,
                        try self.tree().iterator(),
                    );
                }

                pub fn iteratorFromEnd(self: *const Self) Error!?Iterator {
                    return ReadIteratorT.wrap(
                        self.allocator_value,
                        try self.tree().iteratorFromEnd(),
                    );
                }

                pub fn find(self: *const Self, key: ModelT.KeyLikeType) Error!?Iterator {
                    return ReadIteratorT.wrap(
                        self.allocator_value,
                        try self.tree().find(key),
                    );
                }

                pub fn lowerBound(self: *const Self, key: ModelT.KeyLikeType) Error!?Iterator {
                    return ReadIteratorT.wrap(
                        self.allocator_value,
                        try self.tree().lowerBound(key),
                    );
                }
            };

            const BindingT = struct {
                pub const Manager = ManagerT;
                pub const Model = ModelT;
                pub const Tree = TreeT;
                pub const Proxy = MutableProxyT;
                pub const ConstProxy = ConstProxyT;
                pub const Runtime = struct {
                    page_kinds: component.PageKindRange,
                    manager: ManagerT,
                    model: ModelT,
                    tree: TreeT,
                    const_proxy: ConstProxy,
                    allocator_value: std.mem.Allocator,
                    active_editor: bool = false,
                };
                pub const InitOptions = if (CompareContextT == void)
                    struct { compare_context: void = {} }
                else
                    struct { compare_context: CompareContextT };
                pub const TransactionState = ?ManagerT.PageId;
                pub const Error = Proxy.Error || error{InvalidPageKinds};
                pub const StaticMetadata = struct {
                    const PackedPageId = PackedInt(CacheT.Pid, .little);

                    pub const Storage = extern struct {
                        // Page zero is reserved for the database superblock, so zero denotes no root.
                        root: PackedPageId,
                    };
                    pub const Error = error{BadMetadata};

                    pub fn capture(runtime: *const Runtime) Storage {
                        return .{ .root = PackedPageId.init(runtime.manager.getRoot() orelse 0) };
                    }

                    pub fn restore(runtime: *Runtime, storage: *const Storage) void {
                        const root = storage.root.get();
                        runtime.manager.restoreRoot(if (root == 0) null else root);
                    }

                    pub fn validate(storage: *const Storage, page_count: usize) @This().Error!void {
                        const root = storage.root.get();
                        if (root == 0) {
                            return;
                        }
                        const root_index = std.math.cast(usize, root) orelse return error.BadMetadata;
                        if (root_index >= page_count) {
                            return error.BadMetadata;
                        }
                    }
                };

                pub const DynamicMetadata = struct {
                    pub const format_version: u32 = 1;
                    pub const known_tags: []const u16 = &.{0x0100};
                    pub const repeated_tags: []const u16 = &.{};
                    pub const Error = dynamic_metadata.Error;

                    pub fn restore(
                        runtime: *Runtime,
                        payload: []const u8,
                        page_count: usize,
                    ) @This().Error!void {
                        try tagged.validateKnownFields(payload, known_tags);
                        var root: ?CacheT.Pid = null;
                        var found_root = false;
                        var reader = tagged.Reader.init(payload);
                        while (try reader.next()) |field| {
                            if (field.tag != known_tags[0]) {
                                continue;
                            }
                            root = try dynamic_metadata.decodeOptionalPageId(
                                CacheT.Pid,
                                try dynamic_metadata.readU64(field),
                                page_count,
                            );
                            found_root = true;
                        }
                        if (!found_root) {
                            return error.BadMetadata;
                        }
                        runtime.manager.restoreRoot(root);
                    }

                    pub fn encodeKnown(
                        runtime: *const Runtime,
                        writer: *tagged.Writer,
                    ) @This().Error!void {
                        const root = runtime.manager.getRoot() orelse 0;
                        try dynamic_metadata.appendU64(writer, known_tags[0], root);
                    }
                };

                pub fn Gc(comptime CollectorT: type) type {
                    if (CollectorT.PageId != CacheT.Pid) {
                        @compileError("fullaz-db BPT GC collector PageId must match CacheType.Pid");
                    }
                    return struct {
                        pub const RootsError = std.mem.Allocator.Error;
                        pub const RegisterError = CollectorT.Error;
                        const leaf_scanner_version: CollectorT.ScannerVersion = 1;
                        const inode_scanner_version: CollectorT.ScannerVersion = 1;

                        pub fn appendRoots(
                            runtime: *const Runtime,
                            allocator: std.mem.Allocator,
                            roots: *std.ArrayList(CollectorT.PageId),
                        ) RootsError!void {
                            if (runtime.manager.getRoot()) |root| {
                                try roots.append(allocator, root);
                            }
                        }

                        pub fn registerScanners(
                            runtime: *const Runtime,
                            collector: *CollectorT,
                        ) RegisterError!void {
                            const leaf_page_kind = runtime.page_kinds.kindAt(0) orelse unreachable;
                            const inode_page_kind = runtime.page_kinds.kindAt(1) orelse unreachable;
                            try collector.registerForCycle(
                                leaf_page_kind,
                                leaf_scanner_version,
                                &runtime.tree,
                                gc.scanners.method(CollectorT, TreeT, TreeT.scanLeafRefs),
                                null,
                            );
                            try collector.registerForCycle(
                                inode_page_kind,
                                inode_scanner_version,
                                &runtime.tree,
                                gc.scanners.method(CollectorT, TreeT, TreeT.scanInodeRefs),
                                null,
                            );
                        }
                    };
                }

                pub fn initRuntime(
                    runtime: *Runtime,
                    backend: *BackendT,
                    page_kinds: component.PageKindRange,
                    init_options: InitOptions,
                ) Error!void {
                    if (page_kinds.count != page_kind_count) {
                        return Error.InvalidPageKinds;
                    }
                    const leaf_page_kind = page_kinds.kindAt(0) orelse
                        return Error.InvalidPageKinds;
                    const inode_page_kind = page_kinds.kindAt(1) orelse
                        return Error.InvalidPageKinds;

                    runtime.page_kinds = page_kinds;
                    runtime.manager = ManagerT.init(backend);
                    runtime.model = try ModelT.init(
                        backend.cache(),
                        &runtime.manager,
                        .{
                            .maximum_key_size = configured_maximum_key_size,
                            .maximum_value_size = configured_maximum_value_size,
                            .fixed_value_size = configured_fixed_value_size,
                            .leaf_page_kind = leaf_page_kind,
                            .inode_page_kind = inode_page_kind,
                        },
                        init_options.compare_context,
                    );
                    runtime.tree = TreeT.init(&runtime.model, configured_rebalance_policy);
                    runtime.allocator_value = backend.allocator();
                    runtime.active_editor = false;
                    runtime.const_proxy = ConstProxy.init(
                        &runtime.tree,
                        runtime.allocator_value,
                    );
                }

                pub fn deinitRuntime(runtime: *Runtime) void {
                    requireTransactionIdle(runtime) catch
                        @panic("BPT runtime deinitialized with an active value editor");
                    runtime.tree.deinit();
                    runtime.model.deinit();
                    runtime.* = undefined;
                }

                pub fn reclaimPersistent(runtime: *Runtime) Error!void {
                    try requireTransactionIdle(runtime);
                    try runtime.tree.destroy();
                }

                pub fn requireTransactionIdle(runtime: *const Runtime) Error!void {
                    if (runtime.active_editor) {
                        return error.ValueEditorActive;
                    }
                }

                pub fn captureTransactionState(runtime: *const Runtime) TransactionState {
                    return runtime.manager.getRoot();
                }

                pub fn restoreTransactionState(runtime: *Runtime, state: TransactionState) void {
                    runtime.manager.restoreRoot(state);
                }

                pub fn proxy(runtime: *Runtime) Proxy {
                    return Proxy.init(
                        &runtime.tree,
                        runtime.manager.cache_ptr,
                        runtime.allocator_value,
                        &runtime.active_editor,
                    );
                }

                pub fn proxyConst(runtime: *const Runtime) *const ConstProxy {
                    return &runtime.const_proxy;
                }
            };
            comptime component.assertDynamicMetadata(BindingT, BindingT.DynamicMetadata);
            comptime component.assertBinding(BindingT, BackendT);
            comptime component.assertReclamation(BindingT);
            return BindingT;
        }
    };
    return component.descriptor(Trait);
}
