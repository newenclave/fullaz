const std = @import("std");
const component = @import("../component.zig");
const single_root_manager = @import("single_root_manager.zig");
const algorithm = @import("../../core/algorithm.zig");
const interfaces = @import("../../contracts/interfaces.zig");
const PackedInt = @import("../../core/packed_int.zig").PackedInt;
const low_level_bpt = @import("../../bpt/bpt.zig");

fn requireOption(comptime OptionsT: type, comptime name: []const u8) void {
    if (!@hasField(OptionsT, name)) {
        @compileError("Missing pages.bpt option: " ++ name);
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
        std.mem.eql(u8, name, "rebalance_policy") or
        std.mem.eql(u8, name, "format_version");
}

pub fn bpt(comptime options: anytype) component.Descriptor {
    @setEvalBranchQuota(20_000);
    const OptionsT = @TypeOf(options);
    const options_info = @typeInfo(OptionsT);
    if (options_info != .@"struct" or options_info.@"struct".is_tuple) {
        @compileError("pages.bpt options must be a named struct");
    }
    inline for (options_info.@"struct".fields) |field| {
        if (comptime !isKnownOption(field.name)) {
            @compileError("Unknown pages.bpt option: " ++ field.name);
        }
    }
    requireOption(OptionsT, "compare");
    requireOption(OptionsT, "CompareContext");
    requireOption(OptionsT, "comparator_id");
    requireOption(OptionsT, "maximum_key_size");
    requireOption(OptionsT, "maximum_value_size");

    if (@TypeOf(options.CompareContext) != type) {
        @compileError("pages.bpt CompareContext must be a type");
    }
    const CompareContextT = options.CompareContext;
    const CompareFn = fn (CompareContextT, []const u8, []const u8) algorithm.Order;
    if (@TypeOf(options.compare) != CompareFn) {
        @compileError("pages.bpt compare has an invalid signature");
    }

    const configured_comparator_id = unsignedOption(
        options.comparator_id,
        u32,
        "pages.bpt comparator_id must fit u32",
    );
    if (configured_comparator_id == 0) {
        @compileError("pages.bpt comparator_id cannot be zero");
    }
    const configured_maximum_key_size = unsignedOption(
        options.maximum_key_size,
        usize,
        "pages.bpt maximum_key_size must fit usize",
    );
    const configured_maximum_value_size = unsignedOption(
        options.maximum_value_size,
        usize,
        "pages.bpt maximum_value_size must fit usize",
    );
    const configured_format_version = if (@hasField(OptionsT, "format_version"))
        unsignedOption(
            options.format_version,
            u32,
            "pages.bpt format_version must fit u32",
        )
    else
        1;
    if (configured_format_version == 0) {
        @compileError("pages.bpt format_version cannot be zero");
    }
    if (@hasField(OptionsT, "rebalance_policy")) {
        const PolicyT = @TypeOf(options.rebalance_policy);
        if (PolicyT != @TypeOf(.neighbor_share) and PolicyT != low_level_bpt.RebalancePolicy) {
            @compileError("pages.bpt rebalance_policy has an invalid type");
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
        pub const rebalance_policy = configured_rebalance_policy;

        pub fn Binding(comptime BackendT: type) type {
            interfaces.requiresFnSignature(
                BackendT,
                "allocator",
                fn (*const BackendT) std.mem.Allocator,
            );
            const ManagerT = single_root_manager.SingleRootManager(BackendT);
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
                pub const Iterator = ReadIteratorT;

                tree_ptr: *align(@alignOf(TreeT)) anyopaque,
                cache_ptr: *align(@alignOf(CacheT)) anyopaque,
                allocator_value: std.mem.Allocator,
                transaction_generation: ?u64,

                fn init(
                    tree_value: *TreeT,
                    cache_value: *CacheT,
                    allocator_value: std.mem.Allocator,
                ) Self {
                    return .{
                        .tree_ptr = tree_value,
                        .cache_ptr = cache_value,
                        .allocator_value = allocator_value,
                        .transaction_generation = cache_value.transactionGeneration(),
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
                pub const Iterator = ReadIteratorT;

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
                    manager: ManagerT,
                    model: ModelT,
                    tree: TreeT,
                    const_proxy: ConstProxy,
                    allocator_value: std.mem.Allocator,
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

                    runtime.manager = ManagerT.init(backend);
                    runtime.model = try ModelT.init(
                        backend.cache(),
                        &runtime.manager,
                        .{
                            .maximum_key_size = configured_maximum_key_size,
                            .maximum_value_size = configured_maximum_value_size,
                            .leaf_page_kind = leaf_page_kind,
                            .inode_page_kind = inode_page_kind,
                        },
                        init_options.compare_context,
                    );
                    runtime.tree = TreeT.init(&runtime.model, configured_rebalance_policy);
                    runtime.allocator_value = backend.allocator();
                    runtime.const_proxy = ConstProxy.init(
                        &runtime.tree,
                        runtime.allocator_value,
                    );
                }

                pub fn deinitRuntime(runtime: *Runtime) void {
                    runtime.tree.deinit();
                    runtime.model.deinit();
                    runtime.* = undefined;
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
                    );
                }

                pub fn proxyConst(runtime: *const Runtime) *const ConstProxy {
                    return &runtime.const_proxy;
                }
            };
            comptime component.assertBinding(BindingT, BackendT);
            return BindingT;
        }
    };
    return component.descriptor(Trait);
}
