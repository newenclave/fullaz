const std = @import("std");
const component = @import("../component/component.zig");
const FingerprintWriter = @import("../component/fingerprint.zig").Writer;
const managers = @import("../component/managers/managers.zig");
const slot_heap_page = @import("fullaz").page.slot_heap;
const slots = @import("fullaz").slots;
const fsm = @import("fullaz").storage.fsm;
const low_level_slot_heap = @import("fullaz").storage.slot_heap;
const gc = @import("fullaz").gc;
const dynamic_metadata = @import("../file/metadata/dynamic.zig");
const tagged = @import("../file/tagged_fields.zig");

pub const SizeClasses = union(enum) {
    one,
    logarithmic: struct {
        base: u8 = 8,
        minimum_tracked_space: ?u16 = null,
    },
};

fn requireOption(comptime OptionsT: type, comptime name: []const u8) void {
    if (!@hasField(OptionsT, name)) {
        @compileError("Missing fullaz-db.slotHeap option: " ++ name);
    }
}

fn unsignedOption(comptime value: anytype, comptime T: type, comptime diagnostic: []const u8) T {
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
        std.mem.eql(u8, name, "maximum_level") or
        std.mem.eql(u8, name, "size_classes");
}

pub fn slotHeap(comptime options: anytype) component.Descriptor {
    const OptionsT = @TypeOf(options);
    const info = @typeInfo(OptionsT);

    if (info != .@"struct" or info.@"struct".is_tuple) {
        @compileError("fullaz-db.slotHeap options must be a named struct");
    }
    inline for (info.@"struct".fields) |field| {
        if (comptime !isKnownOption(field.name)) {
            @compileError("Unknown fullaz-db.slotHeap option: " ++ field.name);
        }
    }

    requireOption(OptionsT, "compare");
    requireOption(OptionsT, "CompareContext");
    requireOption(OptionsT, "comparator_id");
    requireOption(OptionsT, "maximum_key_size");
    requireOption(OptionsT, "maximum_value_size");

    if (@TypeOf(options.CompareContext) != type) {
        @compileError("fullaz-db.slotHeap CompareContext must be a type");
    }

    const CompareContextT = options.CompareContext;
    const CompareFn = fn (CompareContextT, []const u8, []const u8) std.math.Order;

    if (@TypeOf(options.compare) != CompareFn) {
        @compileError("fullaz-db.slotHeap compare has an invalid signature");
    }

    const configured_comparator_id = unsignedOption(options.comparator_id, u32, "fullaz-db.slotHeap comparator_id must fit u32");
    const configured_maximum_key_size = unsignedOption(options.maximum_key_size, usize, "fullaz-db.slotHeap maximum_key_size must fit usize");
    const configured_maximum_value_size = unsignedOption(options.maximum_value_size, usize, "fullaz-db.slotHeap maximum_value_size must fit usize");
    const configured_maximum_level = if (@hasField(OptionsT, "maximum_level"))
        unsignedOption(options.maximum_level, usize, "fullaz-db.slotHeap maximum_level must fit usize")
    else
        32;
    const configured_size_classes: SizeClasses = if (@hasField(OptionsT, "size_classes")) blk: {
        if (@TypeOf(options.size_classes) != SizeClasses) {
            @compileError("fullaz-db.slotHeap size_classes must be fullaz-db.SlotHeapSizeClasses");
        }
        break :blk options.size_classes;
    } else .{ .logarithmic = .{} };
    if (configured_comparator_id == 0 or configured_maximum_key_size == 0 or configured_maximum_level == 0) {
        @compileError("fullaz-db.slotHeap comparator_id, maximum_key_size, and maximum_level must be non-zero");
    }
    const minimum_entry_size = slots.Variadic(u16, .little, true).fullSlotSize(configured_maximum_key_size);
    const minimum_tracked_space = std.math.cast(u16, minimum_entry_size) orelse
        @compileError("fullaz-db.slotHeap minimum serialized entry must fit u16");
    const ConfiguredSizeClassPolicy, const configured_size_class_policy, const configured_size_class_count = switch (configured_size_classes) {
        .one => .{ fsm.size_classes.One, fsm.size_classes.One{}, 1 },
        .logarithmic => |settings| blk: {
            const configured_minimum = settings.minimum_tracked_space orelse minimum_tracked_space;
            const value = fsm.size_classes.Logarithmic.init(.{
                .base = settings.base,
                .minimum_tracked_space = configured_minimum,
            }) catch @compileError("fullaz-db.slotHeap has invalid logarithmic size_classes settings");
            break :blk .{ fsm.size_classes.Logarithmic, value, value.count() };
        },
    };

    const Trait = struct {
        pub const kind_name: []const u8 = "fullaz.slot-heap.paged";
        pub const format_version: u32 = 2;
        pub const page_kind_count: usize = 3;
        pub const page_roles: [page_kind_count][]const u8 = .{ "leaf", "inode", "fsm_slab" };
        pub const CompareContext = CompareContextT;
        pub const compare = options.compare;
        pub const comparator_id = configured_comparator_id;
        pub const maximum_key_size = configured_maximum_key_size;
        pub const maximum_value_size = configured_maximum_value_size;
        pub const maximum_level = configured_maximum_level;
        pub const size_classes = configured_size_classes;
        pub const SizeClassPolicy = ConfiguredSizeClassPolicy;
        pub const size_class_policy: SizeClassPolicy = configured_size_class_policy;
        pub const size_class_count = configured_size_class_count;

        pub fn fingerprint(writer: *FingerprintWriter) void {
            writer.writeInt(u32, configured_comparator_id);
            writer.writeInt(u64, @intCast(configured_maximum_key_size));
            writer.writeInt(u64, @intCast(configured_maximum_value_size));
            writer.writeInt(u64, @intCast(configured_maximum_level));
            switch (configured_size_classes) {
                .one => writer.writeBytes("one"),
                .logarithmic => |settings| {
                    writer.writeBytes("logarithmic");
                    writer.writeInt(u8, settings.base);
                    writer.writeInt(u16, settings.minimum_tracked_space orelse 0);
                },
            }
        }

        pub fn Binding(comptime BackendT: type) type {
            const CacheT = BackendT.CacheType;
            const LocationAccessor = slot_heap_page.LeafPageLocationAccessor(CacheT.Pid, u16, .little);
            const PolicyT = ConfiguredSizeClassPolicy;
            const policy = configured_size_class_policy;
            const class_count = configured_size_class_count;
            const StateT = low_level_slot_heap.models.paged.State(
                CacheT.Pid,
                u16,
                configured_maximum_level,
                class_count,
            );

            const StateManagerT = managers.StateManager(BackendT, StateT);
            const StateAdapterT = low_level_slot_heap.models.paged.StateAdapter(
                StateManagerT,
                StateT,
                CacheT.Pid,
                u16,
                configured_maximum_level,
                class_count,
            );
            const FsmModelT = fsm.models.paged.slab.Model(
                CacheT,
                StateAdapterT,
                PolicyT,
                LocationAccessor,
            );
            const FsmT = fsm.Fsm(FsmModelT);
            const ModelT = low_level_slot_heap.models.Paged(
                CacheT,
                StateAdapterT,
                FsmT,
                options.compare,
                CompareContextT,
            );
            const HeapT = low_level_slot_heap.Heap(ModelT);

            const BindingT = struct {
                const MutableProxy = struct {
                    const Self = @This();

                    pub const Error = HeapT.Error || CacheT.Error;

                    pub const ValueEditor = struct {
                        const EditorSelf = @This();

                        editor: HeapT.ValueEditor,
                        cache: *CacheT,
                        active_editor: *bool,
                        transaction_generation: ?u64,

                        fn requireTransaction(self: *const EditorSelf) MutableProxy.Error!void {
                            if (self.transaction_generation == null or
                                self.cache.transactionGeneration() != self.transaction_generation)
                            {
                                return MutableProxy.Error.TransactionInactive;
                            }
                        }

                        pub fn valueMut(self: *EditorSelf) MutableProxy.Error![]u8 {
                            try self.requireTransaction();
                            return self.editor.valueMut();
                        }

                        pub fn finish(self: *EditorSelf) MutableProxy.Error!void {
                            try self.requireTransaction();
                            self.editor.finish() catch |err| {
                                switch (err) {
                                    error.ValueEditorActive,
                                    error.StructuralMutationActive,
                                    error.StaleIterator,
                                    error.EditorInvalidated,
                                    => return err,
                                    else => self.cache.markTransactionFailed(),
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

                    pub const MutablePeek = struct {
                        const PeekSelf = @This();

                        inner: HeapT.MutablePeek,
                        cache: *CacheT,
                        active_editor: *bool,
                        transaction_generation: ?u64,

                        fn requireTransaction(self: *const PeekSelf) MutableProxy.Error!void {
                            if (self.transaction_generation == null or
                                self.cache.transactionGeneration() != self.transaction_generation)
                            {
                                return MutableProxy.Error.TransactionInactive;
                            }
                        }

                        pub fn key(self: *const PeekSelf) MutableProxy.Error!ModelT.KeyOutType {
                            try self.requireTransaction();
                            return self.inner.key();
                        }

                        pub fn value(self: *const PeekSelf) MutableProxy.Error!ModelT.ValueOutType {
                            try self.requireTransaction();
                            return self.inner.value();
                        }

                        pub fn editValue(self: *PeekSelf) MutableProxy.Error!ValueEditor {
                            try self.requireTransaction();
                            if (self.active_editor.*) {
                                return error.ValueEditorActive;
                            }
                            const editor = try self.inner.editValue();
                            self.active_editor.* = true;
                            return .{
                                .editor = editor,
                                .cache = self.cache,
                                .active_editor = self.active_editor,
                                .transaction_generation = self.transaction_generation,
                            };
                        }

                        pub fn deinit(self: *PeekSelf) void {
                            self.inner.deinit();
                        }
                    };

                    pub const Peek = MutablePeek;

                    heap: *HeapT,
                    cache: *CacheT,
                    transaction_generation: ?u64,
                    active_editor: *bool,

                    fn requireTransaction(self: *const Self) Self.Error!void {
                        if (self.transaction_generation == null or
                            self.cache.transactionGeneration() != self.transaction_generation)
                        {
                            return Self.Error.TransactionInactive;
                        }
                    }

                    pub fn push(self: *const Self, key: []const u8, value: []const u8) Self.Error!void {
                        try self.requireTransaction();
                        self.heap.push(key, value) catch |err| {
                            self.cache.markTransactionFailed();
                            return err;
                        };
                    }

                    pub fn pop(self: *const Self) Self.Error!void {
                        try self.requireTransaction();
                        self.heap.pop() catch |err| {
                            self.cache.markTransactionFailed();
                            return err;
                        };
                    }

                    /// Returned key/value slices borrow a pinned leaf until MutablePeek.deinit().
                    pub fn top(self: *const Self) Self.Error!MutablePeek {
                        try self.requireTransaction();
                        return .{
                            .inner = try self.heap.mutableTop(),
                            .cache = self.cache,
                            .active_editor = self.active_editor,
                            .transaction_generation = self.transaction_generation,
                        };
                    }

                    pub fn openValueEditor(self: *const Self) Self.Error!ValueEditor {
                        try self.requireTransaction();
                        if (self.active_editor.*) {
                            return error.ValueEditorActive;
                        }
                        const editor = try self.heap.openValueEditor();
                        self.active_editor.* = true;
                        return .{
                            .editor = editor,
                            .cache = self.cache,
                            .active_editor = self.active_editor,
                            .transaction_generation = self.transaction_generation,
                        };
                    }

                    pub fn count(self: *const Self) Self.Error!u64 {
                        return self.heap.count();
                    }

                    pub fn isEmpty(self: *const Self) Self.Error!bool {
                        return self.heap.isEmpty();
                    }
                };
                const ReadProxy = struct {
                    pub const Error = HeapT.Error;
                    pub const ConstPeek = HeapT.Peek;
                    pub const Peek = ConstPeek;

                    heap: *HeapT,

                    pub fn count(self: *const @This()) @This().Error!u64 {
                        return self.heap.count();
                    }

                    pub fn isEmpty(self: *const @This()) @This().Error!bool {
                        return self.heap.isEmpty();
                    }

                    /// Returned key/value slices borrow a pinned leaf until Peek.deinit().
                    pub fn top(self: *const @This()) @This().Error!ConstPeek {
                        return self.heap.top();
                    }
                };

                pub const StateManager = StateManagerT;
                pub const StateAdapter = StateAdapterT;
                pub const FsmModel = FsmModelT;
                pub const Model = ModelT;
                pub const Heap = HeapT;
                pub const State = StateT;
                pub const Proxy = MutableProxy;
                pub const ConstProxy = ReadProxy;
                pub const InitOptions = if (CompareContextT == void) struct {
                    compare_context: void = {},
                } else struct {
                    compare_context: CompareContextT,
                };
                pub const TransactionState = StateT;
                pub const Error = HeapT.Error || error{InvalidPageKinds};
                pub const Runtime = struct {
                    page_kinds: component.PageKindRange,
                    cache: *CacheT,
                    state: StateT,
                    state_manager: StateManagerT,
                    state_adapter: StateAdapterT,
                    fsm_model: FsmModelT,
                    fsm: FsmT,
                    model: ModelT,
                    heap: HeapT,
                    const_proxy: ConstProxy,
                    active_editor: bool = false,
                };
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
                        try validatePageId(storage.root, page_count);
                        try validatePageId(storage.cached_top_page, page_count);
                        if (storage.cached_top_page.isMax() != storage.cached_top_slot.isMax()) {
                            return error.BadMetadata;
                        }
                        inline for (storage.available_inode_heads) |head| {
                            try validatePageId(head, page_count);
                        }
                        inline for (storage.fsm_class_roots) |root| {
                            try validatePageId(root, page_count);
                        }
                    }

                    fn validatePageId(page_id: anytype, page_count: usize) @This().Error!void {
                        if (page_id.isMax()) {
                            return;
                        }
                        const index = std.math.cast(usize, page_id.get()) orelse return @This().Error.BadMetadata;
                        if (index >= page_count) {
                            return @This().Error.BadMetadata;
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
                            if (field.tag != known_tags[0]) {
                                continue;
                            }
                            if (field.flags != 0 or field.value.len != @sizeOf(StateT)) {
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

                    pub fn encodeKnown(runtime: *const Runtime, writer: *tagged.Writer) @This().Error!void {
                        try writer.append(known_tags[0], 0, std.mem.asBytes(&runtime.state));
                    }
                };

                pub fn Gc(comptime CollectorT: type) type {
                    if (CollectorT.PageId != CacheT.Pid) {
                        @compileError("fullaz-db SlotHeap GC collector PageId must match CacheType.Pid");
                    }
                    return struct {
                        pub const RootsError = std.mem.Allocator.Error;
                        pub const RegisterError = CollectorT.Error;
                        const leaf_scanner_version: CollectorT.ScannerVersion = 1;
                        const inode_scanner_version: CollectorT.ScannerVersion = 1;
                        const slab_scanner_version: CollectorT.ScannerVersion = 1;

                        pub fn appendRoots(
                            runtime: *const Runtime,
                            allocator: std.mem.Allocator,
                            roots: *std.ArrayList(CollectorT.PageId),
                        ) RootsError!void {
                            if (!runtime.state.root.isMax()) {
                                try roots.append(allocator, runtime.state.root.get());
                            }
                            for (runtime.state.fsm_class_roots) |root| {
                                if (!root.isMax()) {
                                    try roots.append(allocator, root.get());
                                }
                            }
                        }

                        pub fn registerScanners(
                            runtime: *const Runtime,
                            collector: *CollectorT,
                        ) RegisterError!void {
                            const leaf_page_kind = runtime.page_kinds.kindAt(0) orelse unreachable;
                            const inode_page_kind = runtime.page_kinds.kindAt(1) orelse unreachable;
                            const slab_page_kind = runtime.page_kinds.kindAt(2) orelse unreachable;
                            try collector.registerForCycle(
                                leaf_page_kind,
                                leaf_scanner_version,
                                &runtime.heap,
                                gc.scanners.method(CollectorT, HeapT, HeapT.scanLeafRefs),
                                null,
                            );
                            try collector.registerForCycle(
                                inode_page_kind,
                                inode_scanner_version,
                                &runtime.heap,
                                gc.scanners.method(CollectorT, HeapT, HeapT.scanInodeRefs),
                                null,
                            );
                            try collector.registerForCycle(
                                slab_page_kind,
                                slab_scanner_version,
                                &runtime.fsm,
                                gc.scanners.method(CollectorT, FsmT, FsmT.scanSlabRefs),
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

                    const leaf_kind = page_kinds.kindAt(0) orelse return Error.InvalidPageKinds;
                    const inode_kind = page_kinds.kindAt(1) orelse return Error.InvalidPageKinds;
                    const slab_kind = page_kinds.kindAt(2) orelse return Error.InvalidPageKinds;

                    runtime.page_kinds = page_kinds;
                    runtime.cache = backend.cache();
                    runtime.state = .{};
                    runtime.state_manager = StateManagerT.init(backend, &runtime.state);
                    runtime.state_adapter = StateAdapterT.init(&runtime.state_manager);
                    runtime.fsm_model = FsmModelT.init(backend.cache(), &runtime.state_adapter, policy, .{ .page_kind = slab_kind });
                    runtime.fsm = FsmT.init(&runtime.fsm_model);
                    runtime.model = try ModelT.init(backend.cache(), &runtime.state_adapter, &runtime.fsm, .{ .key_size = configured_maximum_key_size, .maximum_value_size = configured_maximum_value_size, .comparator_id = configured_comparator_id, .leaf_page_kind = leaf_kind, .inode_page_kind = inode_kind, .maximum_level = configured_maximum_level }, init_options.compare_context);
                    runtime.heap = HeapT.init(&runtime.model);
                    runtime.active_editor = false;
                    runtime.const_proxy = .{ .heap = &runtime.heap };
                }

                pub fn deinitRuntime(runtime: *Runtime) void {
                    requireTransactionIdle(runtime) catch
                        @panic("SlotHeap runtime deinitialized with an active value editor");
                    runtime.* = undefined;
                }

                pub fn reclaimPersistent(runtime: *Runtime) Error!void {
                    try requireTransactionIdle(runtime);
                    try runtime.heap.clear();
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
                    return .{
                        .heap = &runtime.heap,
                        .cache = runtime.cache,
                        .transaction_generation = runtime.cache.transactionGeneration(),
                        .active_editor = &runtime.active_editor,
                    };
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
