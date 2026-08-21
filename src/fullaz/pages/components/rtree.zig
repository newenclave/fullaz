const std = @import("std");
const component = @import("../component.zig");
const single_root_manager = @import("single_root_manager.zig");
const low_level_rtree = @import("../../spatial/rtree/rtree.zig");
const PackedInt = @import("../../core/packed_int.zig").PackedInt;
const FingerprintWriter = @import("../schema_fingerprint.zig").Writer;

fn requireOption(comptime OptionsT: type, comptime name: []const u8) void {
    if (!@hasField(OptionsT, name)) {
        @compileError("Missing pages.rtree option: " ++ name);
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
    return std.mem.eql(u8, name, "Coord") or
        std.mem.eql(u8, name, "dimensions") or
        std.mem.eql(u8, name, "maximum_entries") or
        std.mem.eql(u8, name, "maximum_value_size") or
        std.mem.eql(u8, name, "format_version");
}

fn callbackInfo(comptime CallbackT: type) std.builtin.Type.Fn {
    return switch (@typeInfo(CallbackT)) {
        .@"fn" => |info| info,
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => |info| info,
            else => @compileError("pages.rtree callback must be a function or function pointer"),
        },
        else => @compileError("pages.rtree callback must be a function or function pointer"),
    };
}

fn finiteCallbackError(comptime CallbackT: type) type {
    const ReturnT = callbackInfo(CallbackT).return_type orelse
        @compileError("pages.rtree callback must have a return type");
    return switch (@typeInfo(ReturnT)) {
        .void => error{},
        .error_union => |error_union| blk: {
            if (error_union.payload != void) {
                @compileError("pages.rtree callback must return void or a finite error union with void payload");
            }
            const ErrorSet = error_union.error_set;
            if (@typeInfo(ErrorSet).error_set == null) {
                @compileError("pages.rtree callback error set cannot be anyerror");
            }
            break :blk ErrorSet;
        },
        else => @compileError("pages.rtree callback must return void or a finite error union with void payload"),
    };
}

pub fn rtree(comptime options: anytype) component.Descriptor {
    @setEvalBranchQuota(20_000);
    const OptionsT = @TypeOf(options);
    const options_info = @typeInfo(OptionsT);
    if (options_info != .@"struct" or options_info.@"struct".is_tuple) {
        @compileError("pages.rtree options must be a named struct");
    }
    inline for (options_info.@"struct".fields) |field| {
        if (comptime !isKnownOption(field.name)) {
            @compileError("Unknown pages.rtree option: " ++ field.name);
        }
    }
    requireOption(OptionsT, "Coord");
    requireOption(OptionsT, "dimensions");
    requireOption(OptionsT, "maximum_entries");
    requireOption(OptionsT, "maximum_value_size");

    if (@TypeOf(options.Coord) != type) {
        @compileError("pages.rtree Coord must be a type");
    }
    const CoordT = options.Coord;
    const CoordInfo = @typeInfo(CoordT);
    switch (CoordInfo) {
        .int => |int_info| {
            if (int_info.signedness != .signed) {
                @compileError("pages.rtree Coord must be a signed integer or float");
            }
        },
        .float => {},
        else => @compileError("pages.rtree Coord must be a signed integer or float"),
    }
    if (@bitSizeOf(CoordT) != @sizeOf(CoordT) * 8) {
        @compileError("pages.rtree Coord must have a byte-aligned representation");
    }

    const configured_dimensions = unsignedOption(
        options.dimensions,
        usize,
        "pages.rtree dimensions must fit usize",
    );
    if (configured_dimensions == 0) {
        @compileError("pages.rtree dimensions must be greater than zero");
    }
    const configured_maximum_entries = unsignedOption(
        options.maximum_entries,
        usize,
        "pages.rtree maximum_entries must fit usize",
    );
    if (configured_maximum_entries < 4) {
        @compileError("pages.rtree maximum_entries must be at least 4");
    }
    const configured_maximum_value_size = unsignedOption(
        options.maximum_value_size,
        usize,
        "pages.rtree maximum_value_size must fit usize",
    );
    if (std.math.cast(u16, configured_maximum_value_size) == null) {
        @compileError("pages.rtree maximum_value_size must fit u16");
    }
    const mbr_byte_count = std.math.mul(
        usize,
        std.math.mul(
            usize,
            configured_dimensions,
            2,
        ) catch @compileError("pages.rtree dimensions are too large"),
        @sizeOf(CoordT),
    ) catch @compileError("pages.rtree dimensions are too large");
    const maximum_leaf_slot_size = std.math.add(
        usize,
        mbr_byte_count,
        configured_maximum_value_size,
    ) catch @compileError("pages.rtree maximum leaf slot must fit u16");
    if (std.math.cast(u16, maximum_leaf_slot_size) == null) {
        @compileError("pages.rtree maximum leaf slot must fit u16");
    }
    const configured_format_version = if (@hasField(OptionsT, "format_version"))
        unsignedOption(
            options.format_version,
            u32,
            "pages.rtree format_version must fit u32",
        )
    else
        1;
    if (configured_format_version == 0) {
        @compileError("pages.rtree format_version cannot be zero");
    }

    const Trait = struct {
        pub const kind_name: []const u8 = "fullaz.rtree.paged";
        pub const format_version: u32 = configured_format_version;
        pub const page_kind_count: usize = 2;
        pub const page_roles: [page_kind_count][]const u8 = .{ "leaf", "inode" };
        pub const Coord = CoordT;
        pub const dimensions: usize = configured_dimensions;
        pub const maximum_entries: usize = configured_maximum_entries;
        pub const maximum_value_size: usize = configured_maximum_value_size;

        pub fn fingerprint(writer: *FingerprintWriter) void {
            writer.writeInt(usize, dimensions);
            writer.writeInt(usize, maximum_entries);
            writer.writeInt(usize, maximum_value_size);
            writer.writeCoord(Coord);
        }

        pub fn Binding(comptime BackendT: type) type {
            const ManagerT = single_root_manager.SingleRootManager(BackendT);
            comptime low_level_rtree.models.interfaces.requiresStorageManager(ManagerT);
            const CacheT = BackendT.CacheType;
            const ModelT = low_level_rtree.models.Paged(
                CacheT,
                ManagerT,
                CoordT,
                configured_dimensions,
                configured_maximum_entries,
                configured_maximum_value_size,
                .little,
            );
            const TreeT = low_level_rtree.RTree(ModelT);
            const is_float = @typeInfo(CoordT) == .float;

            const isValidBoundingBox = struct {
                fn call(mbr: ModelT.KeyType) bool {
                    if (!mbr.valid()) {
                        return false;
                    }
                    if (comptime is_float) {
                        inline for (mbr.low, mbr.high) |low, high| {
                            if (!std.math.isFinite(low) or !std.math.isFinite(high)) {
                                return false;
                            }
                        }
                    }
                    return true;
                }
            }.call;

            const MutableProxyT = struct {
                const Self = @This();

                pub const BoundingBox = ModelT.KeyType;
                pub const Error = TreeT.Error ||
                    CacheT.Error ||
                    error{InvalidBoundingBox};

                tree_ptr: *align(@alignOf(TreeT)) anyopaque,
                cache_ptr: *align(@alignOf(CacheT)) anyopaque,
                transaction_generation: ?u64,

                fn init(tree_value: *TreeT, cache_value: *CacheT) Self {
                    return .{
                        .tree_ptr = tree_value,
                        .cache_ptr = cache_value,
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

                fn requireValidMutationBox(self: *const Self, mbr: BoundingBox) Error!void {
                    if (!isValidBoundingBox(mbr)) {
                        self.cache().markTransactionFailed();
                        return Error.InvalidBoundingBox;
                    }
                }

                fn SearchError(comptime CallbackT: type) type {
                    return TreeT.Error ||
                        error{InvalidBoundingBox} ||
                        finiteCallbackError(CallbackT);
                }

                pub fn insert(self: *const Self, mbr: BoundingBox, value: []const u8) Error!void {
                    try self.requireTransaction();
                    try self.requireValidMutationBox(mbr);
                    return self.tree().insert(mbr, value) catch |err| {
                        self.cache().markTransactionFailed();
                        return err;
                    };
                }

                pub fn remove(
                    self: *const Self,
                    query: BoundingBox,
                    context: anytype,
                    matches: anytype,
                ) Error!bool {
                    try self.requireTransaction();
                    try self.requireValidMutationBox(query);
                    return self.tree().remove(query, context, matches) catch |err| {
                        self.cache().markTransactionFailed();
                        return err;
                    };
                }

                pub fn search(
                    self: *const Self,
                    query: BoundingBox,
                    context: anytype,
                    callback: anytype,
                ) SearchError(@TypeOf(callback))!void {
                    // Values borrow a pinned leaf page and expire when callback returns.
                    if (!isValidBoundingBox(query)) {
                        return error.InvalidBoundingBox;
                    }
                    return self.tree().search(query, context, callback);
                }

                pub fn searchIntersecting(
                    self: *const Self,
                    query: BoundingBox,
                    context: anytype,
                    callback: anytype,
                ) SearchError(@TypeOf(callback))!void {
                    if (!isValidBoundingBox(query)) {
                        return error.InvalidBoundingBox;
                    }
                    return self.tree().searchIntersecting(query, context, callback);
                }
            };

            const ConstProxyT = struct {
                const Self = @This();

                pub const BoundingBox = ModelT.KeyType;
                pub const Error = TreeT.Error || error{InvalidBoundingBox};

                tree_ptr: *align(@alignOf(TreeT)) const anyopaque,

                fn init(tree_value: *const TreeT) Self {
                    return .{ .tree_ptr = tree_value };
                }

                fn tree(self: *const Self) *const TreeT {
                    return @ptrCast(self.tree_ptr);
                }

                fn SearchError(comptime CallbackT: type) type {
                    return TreeT.Error ||
                        error{InvalidBoundingBox} ||
                        finiteCallbackError(CallbackT);
                }

                pub fn search(
                    self: *const Self,
                    query: BoundingBox,
                    context: anytype,
                    callback: anytype,
                ) SearchError(@TypeOf(callback))!void {
                    // Values borrow a pinned leaf page and expire when callback returns.
                    if (!isValidBoundingBox(query)) {
                        return error.InvalidBoundingBox;
                    }
                    return self.tree().search(query, context, callback);
                }

                pub fn searchIntersecting(
                    self: *const Self,
                    query: BoundingBox,
                    context: anytype,
                    callback: anytype,
                ) SearchError(@TypeOf(callback))!void {
                    if (!isValidBoundingBox(query)) {
                        return error.InvalidBoundingBox;
                    }
                    return self.tree().searchIntersecting(query, context, callback);
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
                };
                pub const InitOptions = struct {};
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
                    _: InitOptions,
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
                            .leaf_page_kind = leaf_page_kind,
                            .inode_page_kind = inode_page_kind,
                        },
                    );
                    runtime.tree = TreeT.init(&runtime.model);
                    runtime.const_proxy = ConstProxy.init(&runtime.tree);
                }

                pub fn deinitRuntime(runtime: *Runtime) void {
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
                    return Proxy.init(&runtime.tree, runtime.manager.cache_ptr);
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
