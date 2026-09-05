const std = @import("std");
const component = @import("../component/component.zig");
const managers = @import("../component/managers/managers.zig");
const low_level_rtree = @import("fullaz").spatial.rtree;
const gc = @import("fullaz").gc;
const FingerprintWriter = @import("../component/fingerprint.zig").Writer;
const dynamic_metadata = @import("../file/metadata/dynamic.zig");
const tagged = @import("../file/tagged_fields.zig");

fn requireOption(comptime OptionsT: type, comptime name: []const u8) void {
    if (!@hasField(OptionsT, name)) {
        @compileError("Missing fullaz-db.rtree option: " ++ name);
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
            else => @compileError("fullaz-db.rtree callback must be a function or function pointer"),
        },
        else => @compileError("fullaz-db.rtree callback must be a function or function pointer"),
    };
}

fn finiteCallbackError(comptime CallbackT: type) type {
    const ReturnT = callbackInfo(CallbackT).return_type orelse
        @compileError("fullaz-db.rtree callback must have a return type");

    return switch (@typeInfo(ReturnT)) {
        .void => error{},
        .error_union => |error_union| blk: {
            if (error_union.payload != void) {
                @compileError("fullaz-db.rtree callback must return void or a finite error union with void payload");
            }
            const ErrorSet = error_union.error_set;
            if (@typeInfo(ErrorSet).error_set == null) {
                @compileError("fullaz-db.rtree callback error set cannot be anyerror");
            }
            break :blk ErrorSet;
        },
        else => @compileError("fullaz-db.rtree callback must return void or a finite error union with void payload"),
    };
}

fn editableCallbackPointer(
    comptime ContextT: type,
    comptime BoundingBoxT: type,
    comptime EditorT: type,
    comptime CallbackT: type,
) type {
    const ReturnT = callbackInfo(CallbackT).return_type.?;
    return switch (@typeInfo(ReturnT)) {
        .void => *const fn (ContextT, BoundingBoxT, *EditorT) void,
        .error_union => *const fn (
            ContextT,
            BoundingBoxT,
            *EditorT,
        ) finiteCallbackError(CallbackT)!void,
        else => unreachable,
    };
}

pub fn rtree(comptime options: anytype) component.Descriptor {
    @setEvalBranchQuota(20_000);

    const OptionsT = @TypeOf(options);
    const options_info = @typeInfo(OptionsT);

    if (options_info != .@"struct" or options_info.@"struct".is_tuple) {
        @compileError("fullaz-db.rtree options must be a named struct");
    }

    inline for (options_info.@"struct".fields) |field| {
        if (comptime !isKnownOption(field.name)) {
            @compileError("Unknown fullaz-db.rtree option: " ++ field.name);
        }
    }

    requireOption(OptionsT, "Coord");
    requireOption(OptionsT, "dimensions");
    requireOption(OptionsT, "maximum_entries");
    requireOption(OptionsT, "maximum_value_size");

    if (@TypeOf(options.Coord) != type) {
        @compileError("fullaz-db.rtree Coord must be a type");
    }
    const CoordT = options.Coord;
    const CoordInfo = @typeInfo(CoordT);
    switch (CoordInfo) {
        .int => |int_info| {
            if (int_info.signedness != .signed) {
                @compileError("fullaz-db.rtree Coord must be a signed integer or float");
            }
        },
        .float => {},
        else => @compileError("fullaz-db.rtree Coord must be a signed integer or float"),
    }
    if (@bitSizeOf(CoordT) != @sizeOf(CoordT) * 8) {
        @compileError("fullaz-db.rtree Coord must have a byte-aligned representation");
    }

    const configured_dimensions = unsignedOption(
        options.dimensions,
        usize,
        "fullaz-db.rtree dimensions must fit usize",
    );
    if (configured_dimensions == 0) {
        @compileError("fullaz-db.rtree dimensions must be greater than zero");
    }
    const configured_maximum_entries = unsignedOption(
        options.maximum_entries,
        usize,
        "fullaz-db.rtree maximum_entries must fit usize",
    );
    if (configured_maximum_entries < 4) {
        @compileError("fullaz-db.rtree maximum_entries must be at least 4");
    }
    const configured_maximum_value_size = unsignedOption(
        options.maximum_value_size,
        usize,
        "fullaz-db.rtree maximum_value_size must fit usize",
    );
    if (std.math.cast(u16, configured_maximum_value_size) == null) {
        @compileError("fullaz-db.rtree maximum_value_size must fit u16");
    }
    const mbr_byte_count = std.math.mul(
        usize,
        std.math.mul(
            usize,
            configured_dimensions,
            2,
        ) catch @compileError("fullaz-db.rtree dimensions are too large"),
        @sizeOf(CoordT),
    ) catch @compileError("fullaz-db.rtree dimensions are too large");
    const maximum_leaf_slot_size = std.math.add(
        usize,
        mbr_byte_count,
        configured_maximum_value_size,
    ) catch @compileError("fullaz-db.rtree maximum leaf slot must fit u16");
    if (std.math.cast(u16, maximum_leaf_slot_size) == null) {
        @compileError("fullaz-db.rtree maximum leaf slot must fit u16");
    }
    const configured_format_version = if (@hasField(OptionsT, "format_version"))
        unsignedOption(
            options.format_version,
            u32,
            "fullaz-db.rtree format_version must fit u32",
        )
    else
        2;
    if (configured_format_version == 0) {
        @compileError("fullaz-db.rtree format_version cannot be zero");
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
            writer.writeInt(u64, @intCast(dimensions));
            writer.writeInt(u64, @intCast(maximum_entries));
            writer.writeInt(u64, @intCast(maximum_value_size));
            writer.writeCoord(Coord);
        }

        pub fn Binding(comptime BackendT: type) type {
            const CacheT = BackendT.CacheType;
            const StateT = low_level_rtree.models.paged.State(CacheT.Pid);
            const ManagerT = managers.StateManager(BackendT, StateT);
            comptime low_level_rtree.models.interfaces.requiresStorageManager(ManagerT, CacheT.Pid);
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

            const ProxyFactory = struct {
                fn Mutable(comptime ProxyModelT: type, comptime ProxyTreeT: type) type {
                    const isValidBoundingBox = struct {
                        fn call(mbr: ProxyModelT.KeyType) bool {
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

                    return struct {
                        const Self = @This();

                        pub const BoundingBox = ProxyModelT.KeyType;
                        pub const Error = ProxyTreeT.Error ||
                            CacheT.Error ||
                            error{InvalidBoundingBox};

                        pub const ValueEditor = struct {
                            const EditorSelf = @This();

                            editor: ProxyTreeT.ValueEditor,
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

                        pub const SearchValueEditor = struct {
                            const EditorSelf = @This();

                            editor: *ProxyTreeT.ValueEditor,
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

                        tree_ptr: *align(@alignOf(ProxyTreeT)) anyopaque,
                        cache_ptr: *align(@alignOf(CacheT)) anyopaque,
                        transaction_generation: ?u64,
                        active_editor: *bool,

                        fn init(tree_value: *ProxyTreeT, cache_value: *CacheT, active_editor: *bool) Self {
                            return .{
                                .tree_ptr = tree_value,
                                .cache_ptr = cache_value,
                                .transaction_generation = cache_value.transactionGeneration(),
                                .active_editor = active_editor,
                            };
                        }

                        fn tree(self: *const Self) *ProxyTreeT {
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
                            return ProxyTreeT.Error ||
                                error{InvalidBoundingBox} ||
                                finiteCallbackError(CallbackT);
                        }

                        fn EditableSearchError(comptime CallbackT: type) type {
                            return Error || finiteCallbackError(CallbackT);
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

                        /// Opens an editor for the first hit selected with remove()'s
                        /// predicate and closed-box intersection rules.
                        pub fn openValueEditor(
                            self: *const Self,
                            query: BoundingBox,
                            context: anytype,
                            matches: anytype,
                        ) Error!?ValueEditor {
                            try self.requireTransaction();
                            if (!isValidBoundingBox(query)) {
                                return error.InvalidBoundingBox;
                            }
                            if (self.active_editor.*) {
                                return error.ValueEditorActive;
                            }
                            const inner_editor = try self.tree().openValueEditor(query, context, matches);
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

                        pub fn searchEditable(
                            self: *const Self,
                            query: BoundingBox,
                            context: anytype,
                            callback: anytype,
                        ) EditableSearchError(@TypeOf(callback))!void {
                            try self.requireTransaction();
                            if (!isValidBoundingBox(query)) {
                                return error.InvalidBoundingBox;
                            }
                            const Context = struct {
                                proxy: *const Self,
                                user_context: @TypeOf(context),
                                user_callback: editableCallbackPointer(
                                    @TypeOf(context),
                                    BoundingBox,
                                    SearchValueEditor,
                                    @TypeOf(callback),
                                ),
                            };
                            const Wrapper = struct {
                                fn call(
                                    wrapped: *Context,
                                    mbr: BoundingBox,
                                    inner_editor: *ProxyTreeT.ValueEditor,
                                ) EditableSearchError(@TypeOf(callback))!void {
                                    if (wrapped.proxy.active_editor.*) {
                                        return error.ValueEditorActive;
                                    }
                                    wrapped.proxy.active_editor.* = true;
                                    var editor = SearchValueEditor{
                                        .editor = inner_editor,
                                        .cache_ptr = wrapped.proxy.cache_ptr,
                                        .active_editor = wrapped.proxy.active_editor,
                                        .transaction_generation = wrapped.proxy.transaction_generation,
                                    };
                                    defer editor.deinit();
                                    const ReturnT = callbackInfo(@TypeOf(callback)).return_type.?;
                                    switch (@typeInfo(ReturnT)) {
                                        .void => wrapped.user_callback(
                                            wrapped.user_context,
                                            mbr,
                                            &editor,
                                        ),
                                        .error_union => try wrapped.user_callback(
                                            wrapped.user_context,
                                            mbr,
                                            &editor,
                                        ),
                                        else => unreachable,
                                    }
                                }
                            };
                            var wrapped = Context{
                                .proxy = self,
                                .user_context = context,
                                .user_callback = callback,
                            };
                            return self.tree().searchEditable(query, &wrapped, Wrapper.call);
                        }

                        pub fn searchIntersectingEditable(
                            self: *const Self,
                            query: BoundingBox,
                            context: anytype,
                            callback: anytype,
                        ) EditableSearchError(@TypeOf(callback))!void {
                            try self.requireTransaction();
                            if (!isValidBoundingBox(query)) {
                                return error.InvalidBoundingBox;
                            }
                            const Context = struct {
                                proxy: *const Self,
                                user_context: @TypeOf(context),
                                user_callback: editableCallbackPointer(
                                    @TypeOf(context),
                                    BoundingBox,
                                    SearchValueEditor,
                                    @TypeOf(callback),
                                ),
                            };
                            const Wrapper = struct {
                                fn call(
                                    wrapped: *Context,
                                    mbr: BoundingBox,
                                    inner_editor: *ProxyTreeT.ValueEditor,
                                ) EditableSearchError(@TypeOf(callback))!void {
                                    if (wrapped.proxy.active_editor.*) {
                                        return error.ValueEditorActive;
                                    }
                                    wrapped.proxy.active_editor.* = true;
                                    var editor = SearchValueEditor{
                                        .editor = inner_editor,
                                        .cache_ptr = wrapped.proxy.cache_ptr,
                                        .active_editor = wrapped.proxy.active_editor,
                                        .transaction_generation = wrapped.proxy.transaction_generation,
                                    };
                                    defer editor.deinit();
                                    const ReturnT = callbackInfo(@TypeOf(callback)).return_type.?;
                                    switch (@typeInfo(ReturnT)) {
                                        .void => wrapped.user_callback(wrapped.user_context, mbr, &editor),
                                        .error_union => try wrapped.user_callback(
                                            wrapped.user_context,
                                            mbr,
                                            &editor,
                                        ),
                                        else => unreachable,
                                    }
                                }
                            };
                            var wrapped = Context{
                                .proxy = self,
                                .user_context = context,
                                .user_callback = callback,
                            };
                            return self.tree().searchIntersectingEditable(query, &wrapped, Wrapper.call);
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
                }

                fn Const(comptime ProxyModelT: type, comptime ProxyTreeT: type) type {
                    const isValidBoundingBox = struct {
                        fn call(mbr: ProxyModelT.KeyType) bool {
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

                    return struct {
                        const Self = @This();

                        pub const BoundingBox = ProxyModelT.KeyType;
                        pub const Error = ProxyTreeT.Error || error{InvalidBoundingBox};

                        tree_ptr: *align(@alignOf(ProxyTreeT)) const anyopaque,

                        fn init(tree_value: *const ProxyTreeT) Self {
                            return .{ .tree_ptr = tree_value };
                        }

                        fn tree(self: *const Self) *const ProxyTreeT {
                            return @ptrCast(self.tree_ptr);
                        }

                        fn SearchError(comptime CallbackT: type) type {
                            return ProxyTreeT.Error ||
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
                }
            };

            const MutableProxyT = ProxyFactory.Mutable(ModelT, TreeT);
            const ConstProxyT = ProxyFactory.Const(ModelT, TreeT);

            const BindingT = struct {
                pub const Manager = ManagerT;
                pub const State = StateT;
                pub const value_capacity: ?usize = configured_maximum_value_size;
                pub const Model = ModelT;
                pub const Tree = TreeT;
                pub const Proxy = MutableProxyT;
                pub const ConstProxy = ConstProxyT;
                pub const Runtime = struct {
                    page_kinds: component.PageKindRange,
                    state: StateT,
                    manager: ManagerT,
                    model: ModelT,
                    tree: TreeT,
                    const_proxy: ConstProxy,
                    active_editor: bool = false,
                };
                pub const InitOptions = struct {};
                pub const TransactionState = StateT;
                pub const Error = Proxy.Error || error{InvalidPageKinds};
                pub const StaticMetadata = struct {
                    pub const Storage = StateT;
                    pub const Error = error{BadMetadata};

                    pub fn capture(runtime: *const Runtime) Storage {
                        return runtime.state;
                    }

                    pub fn restore(runtime: *Runtime, storage: *const Storage) void {
                        runtime.state = storage.*;
                    }

                    pub fn validate(storage: *const Storage, page_count: usize) @This().Error!void {
                        if (storage.root.isMax()) {
                            return;
                        }
                        const root = storage.root.get();
                        const root_index = std.math.cast(usize, root) orelse return error.BadMetadata;
                        if (root_index >= page_count) {
                            return error.BadMetadata;
                        }
                    }
                };
                pub const DynamicMetadata = struct {
                    pub const format_version: u32 = 2;
                    pub const known_tags: []const u16 = &.{0x0100};
                    pub const repeated_tags: []const u16 = &.{};
                    pub const Error = dynamic_metadata.Error;

                    pub fn restore(runtime: *Runtime, payload: []const u8, page_count: usize) @This().Error!void {
                        try tagged.validateKnownFields(payload, known_tags);
                        var state: StateT = undefined;
                        var found_state = false;
                        var reader = tagged.Reader.init(payload);
                        while (try reader.next()) |field| {
                            if (field.tag == known_tags[0]) {
                                if (field.flags != 0 or field.value.len != @sizeOf(StateT)) {
                                    return error.BadMetadata;
                                }
                                @memcpy(std.mem.asBytes(&state), field.value);
                                found_state = true;
                            }
                        }
                        if (!found_state) return error.BadMetadata;
                        try StaticMetadata.validate(&state, page_count);
                        runtime.state = state;
                    }

                    pub fn encodeKnown(runtime: *const Runtime, writer: *tagged.Writer) @This().Error!void {
                        try writer.append(known_tags[0], 0, std.mem.asBytes(&runtime.state));
                    }
                };

                pub fn Gc(comptime CollectorT: type) type {
                    if (CollectorT.PageId != CacheT.Pid) {
                        @compileError("fullaz-db R-tree GC collector PageId must match CacheType.Pid");
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
                            if (!runtime.state.root.isMax()) {
                                try roots.append(allocator, runtime.state.root.get());
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
                    _: InitOptions,
                ) Error!void {
                    if (page_kinds.count != page_kind_count) {
                        return Error.InvalidPageKinds;
                    }
                    const leaf_page_kind = page_kinds.kindAt(0) orelse
                        return Error.InvalidPageKinds;
                    const inode_page_kind = page_kinds.kindAt(1) orelse
                        return Error.InvalidPageKinds;

                    runtime.page_kinds = page_kinds;
                    runtime.state = .{};
                    runtime.manager = ManagerT.init(backend, &runtime.state);
                    runtime.model = try ModelT.init(
                        backend.cache(),
                        &runtime.manager,
                        .{
                            .leaf_page_kind = leaf_page_kind,
                            .inode_page_kind = inode_page_kind,
                        },
                    );
                    runtime.tree = TreeT.init(&runtime.model);
                    runtime.active_editor = false;
                    runtime.const_proxy = ConstProxy.init(&runtime.tree);
                }

                pub fn deinitRuntime(runtime: *Runtime) void {
                    requireTransactionIdle(runtime) catch
                        @panic("R-tree runtime deinitialized with an active value editor");
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
                    return runtime.state;
                }

                pub fn restoreTransactionState(runtime: *Runtime, state: TransactionState) void {
                    runtime.state = state;
                }

                pub fn proxy(runtime: *Runtime) Proxy {
                    return Proxy.init(
                        &runtime.tree,
                        runtime.manager.cache_ptr,
                        &runtime.active_editor,
                    );
                }

                pub fn proxyConst(runtime: *const Runtime) *const ConstProxy {
                    return &runtime.const_proxy;
                }

                pub fn StorageBinding(comptime StorageManagerT: type) type {
                    comptime low_level_rtree.models.interfaces.requiresStorageManager(
                        StorageManagerT,
                        CacheT.Pid,
                    );
                    const StorageModelT = low_level_rtree.models.Paged(
                        CacheT,
                        StorageManagerT,
                        CoordT,
                        configured_dimensions,
                        configured_maximum_entries,
                        configured_maximum_value_size,
                        .little,
                    );
                    const StorageTreeT = low_level_rtree.RTree(StorageModelT);
                    const StorageProxyT = ProxyFactory.Mutable(StorageModelT, StorageTreeT);
                    const StorageConstProxyT = ProxyFactory.Const(StorageModelT, StorageTreeT);
                    const StorageInitOptionsT = struct {};
                    const StorageError = StorageProxyT.Error || error{InvalidPageKinds};
                    const StorageRuntimeT = struct {
                        page_kinds: component.PageKindRange,
                        cache: *CacheT,
                        storage_manager: *StorageManagerT,
                        model: StorageModelT,
                        tree: StorageTreeT,
                        const_proxy: StorageConstProxyT,
                        active_editor: bool = false,
                    };

                    return struct {
                        pub const State = StateT;
                        pub const StorageManager = StorageManagerT;
                        pub const Model = StorageModelT;
                        pub const Tree = StorageTreeT;
                        pub const Proxy = StorageProxyT;
                        pub const ConstProxy = StorageConstProxyT;
                        pub const InitOptions = StorageInitOptionsT;
                        pub const Error = StorageError;
                        pub const Runtime = StorageRuntimeT;
                        pub const value_capacity: ?usize = configured_maximum_value_size;

                        pub fn emptyState() StateT {
                            return .{};
                        }

                        pub fn initRuntime(
                            runtime: *StorageRuntimeT,
                            backend: *BackendT,
                            storage_manager: *StorageManagerT,
                            page_kinds: component.PageKindRange,
                            _: StorageInitOptionsT,
                        ) StorageError!void {
                            if (page_kinds.count != page_kind_count) {
                                return StorageError.InvalidPageKinds;
                            }
                            const leaf_page_kind = page_kinds.kindAt(0) orelse
                                return StorageError.InvalidPageKinds;
                            const inode_page_kind = page_kinds.kindAt(1) orelse
                                return StorageError.InvalidPageKinds;

                            runtime.page_kinds = page_kinds;
                            runtime.cache = backend.cache();
                            runtime.storage_manager = storage_manager;
                            runtime.model = try StorageModelT.init(
                                runtime.cache,
                                runtime.storage_manager,
                                .{
                                    .leaf_page_kind = leaf_page_kind,
                                    .inode_page_kind = inode_page_kind,
                                },
                            );
                            runtime.tree = StorageTreeT.init(&runtime.model);
                            runtime.active_editor = false;
                            runtime.const_proxy = StorageConstProxyT.init(&runtime.tree);
                        }

                        pub fn deinitRuntime(runtime: *StorageRuntimeT) void {
                            if (runtime.active_editor) {
                                @panic("R-tree storage runtime deinitialized with an active value editor");
                            }
                            runtime.model.deinit();
                            runtime.* = undefined;
                        }

                        pub fn requireTransactionIdle(runtime: *const StorageRuntimeT) StorageError!void {
                            if (runtime.active_editor) {
                                return error.ValueEditorActive;
                            }
                        }

                        pub fn proxy(runtime: *StorageRuntimeT) StorageProxyT {
                            return StorageProxyT.init(
                                &runtime.tree,
                                runtime.cache,
                                &runtime.active_editor,
                            );
                        }

                        pub fn proxyConst(runtime: *const StorageRuntimeT) *const StorageConstProxyT {
                            return &runtime.const_proxy;
                        }
                    };
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
