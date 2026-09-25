const std = @import("std");
const component = @import("../component/component.zig");
const managers = @import("../component/managers/managers.zig");
const interfaces = @import("fullaz").contracts.interfaces;
const dynamic_metadata = @import("../file/metadata/dynamic.zig");
const tagged = @import("../file/tagged_fields.zig");
const low_level_radix = @import("fullaz").radix_tree;
const gc = @import("fullaz").gc;
const FingerprintWriter = @import("../component/fingerprint.zig").Writer;

fn requireOption(comptime OptionsT: type, comptime name: []const u8) void {
    if (!@hasField(OptionsT, name)) {
        @compileError("Missing fullaz-db.radix option: " ++ name);
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
    return std.mem.eql(u8, name, "Key") or
        std.mem.eql(u8, name, "value_size") or
        std.mem.eql(u8, name, "format_version");
}

pub fn radix(comptime options: anytype) component.Descriptor {
    @setEvalBranchQuota(20_000);

    const OptionsT = @TypeOf(options);
    const options_info = @typeInfo(OptionsT);
    if (options_info != .@"struct" or options_info.@"struct".is_tuple) {
        @compileError("fullaz-db.radix options must be a named struct");
    }
    inline for (options_info.@"struct".fields) |field| {
        if (comptime !isKnownOption(field.name)) {
            @compileError("Unknown fullaz-db.radix option: " ++ field.name);
        }
    }
    requireOption(OptionsT, "Key");
    requireOption(OptionsT, "value_size");

    if (@TypeOf(options.Key) != type) {
        @compileError("fullaz-db.radix Key must be a type");
    }
    const KeyT = options.Key;
    switch (@typeInfo(KeyT)) {
        .int => |info| {
            if (info.signedness != .unsigned or info.bits < 16) {
                @compileError("fullaz-db.radix Key must be an unsigned integer of at least 16 bits");
            }
        },
        else => @compileError("fullaz-db.radix Key must be an unsigned integer of at least 16 bits"),
    }
    if (KeyT == usize or @bitSizeOf(KeyT) != @sizeOf(KeyT) * 8) {
        @compileError("fullaz-db.radix Key must have a fixed-width byte-aligned representation");
    }

    const configured_value_size = unsignedOption(
        options.value_size,
        usize,
        "fullaz-db.radix value_size must fit usize",
    );
    if (configured_value_size == 0 or
        configured_value_size > std.math.maxInt(u16))
    {
        @compileError("fullaz-db.radix value_size must be between 1 and maxInt(u16)");
    }
    const configured_format_version = if (@hasField(OptionsT, "format_version"))
        unsignedOption(
            options.format_version,
            u32,
            "fullaz-db.radix format_version must fit u32",
        )
    else
        1;
    if (configured_format_version == 0) {
        @compileError("fullaz-db.radix format_version cannot be zero");
    }

    const Trait = struct {
        pub const kind_name: []const u8 = "fullaz.radix.paged";
        pub const format_version: u32 = configured_format_version;
        pub const page_kind_count: usize = 2;
        pub const page_roles: [page_kind_count][]const u8 = .{ "leaf", "inode" };
        pub const Key = KeyT;
        pub const value_size: usize = configured_value_size;

        pub fn fingerprint(writer: *FingerprintWriter) void {
            writer.writeInt(u16, @bitSizeOf(Key));
            writer.writeInt(u64, @intCast(value_size));
        }

        pub fn Binding(comptime BackendT: type) type {
            interfaces.requiresFnSignature(
                BackendT,
                "allocator",
                fn (*const BackendT) std.mem.Allocator,
            );
            const CacheT = BackendT.CacheType;
            const StateT = low_level_radix.models.paged.State(CacheT.Pid, .little);
            const ManagerT = managers.StateManager(BackendT, StateT);
            const ModelT = low_level_radix.models.paged.Model(
                CacheT,
                ManagerT,
                KeyT,
                configured_value_size,
            );
            const TreeT = low_level_radix.Tree(ModelT);

            const ProxyFactory = struct {
                fn get(comptime ProxyTreeT: type) type {
                    const ReadEntryT = struct {
                        const Self = @This();
                        const Inner = ProxyTreeT.Entry;

                        pub const Error = ProxyTreeT.Error || std.mem.Allocator.Error;
                        pub const Result = Inner.Result;

                        entry_ptr: *align(@alignOf(Inner)) anyopaque,
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
                                    .entry_ptr = ptr,
                                    .allocator_value = allocator_value,
                                };
                            }
                            return null;
                        }

                        fn inner(self: *const Self) *Inner {
                            return @ptrCast(self.entry_ptr);
                        }

                        pub fn get(self: *const Self) Error!Result {
                            return self.inner().get();
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

                        pub const Error = ProxyTreeT.Error ||
                            CacheT.Error ||
                            std.mem.Allocator.Error;

                        pub const ValueEditor = struct {
                            const EditorSelf = @This();

                            editor: ProxyTreeT.ValueEditor,
                            cache_ptr: *align(@alignOf(CacheT)) anyopaque,
                            active_editor: *bool,
                            transaction_generation: ?u64,
                            owns_active_editor: bool = true,

                            fn init(
                                editor: ProxyTreeT.ValueEditor,
                                cache_ptr: *align(@alignOf(CacheT)) anyopaque,
                                active_editor: *bool,
                                transaction_generation: ?u64,
                            ) EditorSelf {
                                return .{
                                    .editor = editor,
                                    .cache_ptr = cache_ptr,
                                    .active_editor = active_editor,
                                    .transaction_generation = transaction_generation,
                                };
                            }

                            fn cache(self: *const EditorSelf) *CacheT {
                                return @ptrCast(self.cache_ptr);
                            }

                            fn requireTransaction(self: *const EditorSelf) Error!void {
                                if (self.transaction_generation == null or
                                    self.cache().transactionGeneration() != self.transaction_generation)
                                {
                                    return error.TransactionInactive;
                                }
                            }

                            fn releaseActiveEditor(self: *EditorSelf) void {
                                if (!self.owns_active_editor) {
                                    return;
                                }
                                self.active_editor.* = false;
                                self.owns_active_editor = false;
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
                                self.releaseActiveEditor();
                            }

                            pub fn deinit(self: *EditorSelf) void {
                                self.editor.deinit();
                                self.releaseActiveEditor();
                            }
                        };

                        pub const Entry = struct {
                            const EntrySelf = @This();

                            read_entry: ReadEntryT,
                            cache_ptr: *align(@alignOf(CacheT)) anyopaque,
                            active_editor: *bool,
                            transaction_generation: ?u64,

                            fn wrap(
                                allocator_value: std.mem.Allocator,
                                inner_optional: ?ProxyTreeT.Entry,
                                cache_ptr: *align(@alignOf(CacheT)) anyopaque,
                                active_editor: *bool,
                                transaction_generation: ?u64,
                            ) std.mem.Allocator.Error!?EntrySelf {
                                const read_entry = (try ReadEntryT.wrap(
                                    allocator_value,
                                    inner_optional,
                                )) orelse return null;
                                return .{
                                    .read_entry = read_entry,
                                    .cache_ptr = cache_ptr,
                                    .active_editor = active_editor,
                                    .transaction_generation = transaction_generation,
                                };
                            }

                            fn cache(self: *const EntrySelf) *CacheT {
                                return @ptrCast(self.cache_ptr);
                            }

                            fn requireTransaction(self: *const EntrySelf) Error!void {
                                if (self.transaction_generation == null or
                                    self.cache().transactionGeneration() != self.transaction_generation)
                                {
                                    return error.TransactionInactive;
                                }
                            }

                            pub fn get(self: *const EntrySelf) Error!ReadEntryT.Result {
                                try self.requireTransaction();
                                return self.read_entry.get();
                            }

                            pub fn editValue(self: *EntrySelf) Error!ValueEditor {
                                try self.requireTransaction();
                                if (self.active_editor.*) {
                                    return error.ValueEditorActive;
                                }
                                const editor = try self.read_entry.inner().editValue();
                                self.active_editor.* = true;
                                return ValueEditor.init(
                                    editor,
                                    self.cache_ptr,
                                    self.active_editor,
                                    self.transaction_generation,
                                );
                            }

                            pub fn deinit(self: *EntrySelf) void {
                                self.read_entry.deinit();
                                self.* = undefined;
                            }
                        };

                        tree_ptr: *align(@alignOf(ProxyTreeT)) anyopaque,
                        cache_ptr: *align(@alignOf(CacheT)) anyopaque,
                        allocator_value: std.mem.Allocator,
                        transaction_generation: ?u64,
                        active_editor: *bool,

                        fn init(
                            tree_value: *ProxyTreeT,
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
                                return error.TransactionInactive;
                            }
                        }

                        fn requireExactValue(value: []const u8) Error!void {
                            if (value.len != configured_value_size) {
                                return error.BadLength;
                            }
                        }

                        pub fn find(self: *const Self, key: KeyT) Error!?Entry {
                            try self.requireTransaction();
                            return Entry.wrap(
                                self.allocator_value,
                                try self.tree().find(key),
                                self.cache_ptr,
                                self.active_editor,
                                self.transaction_generation,
                            );
                        }

                        pub fn set(self: *const Self, key: KeyT, value: []const u8) Error!void {
                            try self.requireTransaction();
                            try requireExactValue(value);
                            return self.tree().set(key, value) catch |err| {
                                self.cache().markTransactionFailed();
                                return err;
                            };
                        }

                        pub fn free(self: *const Self, key: KeyT) Error!void {
                            try self.requireTransaction();
                            return self.tree().free(key) catch |err| {
                                self.cache().markTransactionFailed();
                                return err;
                            };
                        }

                        pub fn takeFree(self: *const Self, value: []const u8) Error!?KeyT {
                            try self.requireTransaction();
                            try requireExactValue(value);
                            return self.tree().takeFree(value) catch |err| {
                                self.cache().markTransactionFailed();
                                return err;
                            };
                        }

                        pub fn openValueEditor(
                            self: *const Self,
                            key: KeyT,
                        ) Error!?ValueEditor {
                            try self.requireTransaction();
                            if (self.active_editor.*) {
                                return error.ValueEditorActive;
                            }
                            const editor = (try self.tree().openValueEditor(key)) orelse return null;
                            self.active_editor.* = true;
                            return ValueEditor.init(
                                editor,
                                self.cache_ptr,
                                self.active_editor,
                                self.transaction_generation,
                            );
                        }
                    };

                    const ConstProxyT = struct {
                        const Self = @This();

                        pub const Error = ReadEntryT.Error;
                        pub const Entry = ReadEntryT;

                        tree_ptr: *align(@alignOf(ProxyTreeT)) const anyopaque,
                        allocator_value: std.mem.Allocator,

                        fn init(
                            tree_value: *const ProxyTreeT,
                            allocator_value: std.mem.Allocator,
                        ) Self {
                            return .{
                                .tree_ptr = tree_value,
                                .allocator_value = allocator_value,
                            };
                        }

                        fn tree(self: *const Self) *const ProxyTreeT {
                            return @ptrCast(self.tree_ptr);
                        }

                        pub fn find(self: *const Self, key: KeyT) Error!?Entry {
                            return Entry.wrap(
                                self.allocator_value,
                                try self.tree().find(key),
                            );
                        }
                    };

                    return struct {
                        pub const Mutable = MutableProxyT;
                        pub const Const = ConstProxyT;
                    };
                }
            };

            const ProxyTypesT = ProxyFactory.get(TreeT);
            const MutableProxyT = ProxyTypesT.Mutable;
            const ConstProxyT = ProxyTypesT.Const;

            const BindingT = struct {
                pub const Manager = ManagerT;
                pub const State = StateT;
                pub const Key = KeyT;
                pub const value_capacity: ?usize = configured_value_size;
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
                    allocator_value: std.mem.Allocator,
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

                    fn validatePid(pid: CacheT.Pid, page_count: usize) @This().Error!void {
                        if (pid == 0) {
                            return error.BadMetadata;
                        }
                        const page_index = std.math.cast(usize, pid) orelse
                            return error.BadMetadata;
                        if (page_index >= page_count) {
                            return error.BadMetadata;
                        }
                    }

                    pub fn validate(
                        storage: *const Storage,
                        page_count: usize,
                    ) @This().Error!void {
                        if (storage.root.isMax()) {
                            if (!storage.free_leaf_root.isMax()) {
                                return error.BadMetadata;
                            }
                            return;
                        }
                        try validatePid(storage.root.get(), page_count);
                        if (!storage.free_leaf_root.isMax()) {
                            try validatePid(storage.free_leaf_root.get(), page_count);
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
                        var state: StateT = undefined;
                        var found_state = false;
                        var reader = tagged.Reader.init(payload);
                        while (try reader.next()) |field| {
                            if (field.tag != known_tags[0]) {
                                continue;
                            }
                            if (found_state or field.flags != 0 or
                                field.value.len != @sizeOf(StateT))
                            {
                                return error.BadMetadata;
                            }
                            @memcpy(std.mem.asBytes(&state), field.value);
                            found_state = true;
                        }
                        if (!found_state) {
                            return error.BadMetadata;
                        }
                        try StaticMetadata.validate(&state, page_count);
                        runtime.state = state;
                    }

                    pub fn encodeKnown(
                        runtime: *const Runtime,
                        writer: *tagged.Writer,
                    ) @This().Error!void {
                        try writer.append(known_tags[0], 0, std.mem.asBytes(&runtime.state));
                    }
                };

                pub fn Gc(comptime CollectorT: type) type {
                    if (CollectorT.PageId != CacheT.Pid) {
                        @compileError("fullaz-db Radix GC collector PageId must match CacheType.Pid");
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
                        return error.InvalidPageKinds;
                    }
                    const leaf_page_kind = page_kinds.kindAt(0) orelse
                        return error.InvalidPageKinds;
                    const inode_page_kind = page_kinds.kindAt(1) orelse
                        return error.InvalidPageKinds;

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
                    runtime.allocator_value = backend.allocator();
                    runtime.active_editor = false;
                    runtime.const_proxy = ConstProxy.init(
                        &runtime.tree,
                        runtime.allocator_value,
                    );
                }

                pub fn deinitRuntime(runtime: *Runtime) void {
                    requireTransactionIdle(runtime) catch
                        @panic("Radix runtime deinitialized with an active value editor");
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
                    return runtime.state;
                }

                pub fn restoreTransactionState(runtime: *Runtime, state: TransactionState) void {
                    runtime.state = state;
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
