const std = @import("std");
const PackedInt = @import("../../core/packed_int.zig").PackedInt;
const component = @import("../component.zig");
const FingerprintWriter = @import("../schema_fingerprint.zig").Writer;
const SlotHeapManager = @import("slot_heap_manager.zig").SlotHeapManager;
const slot_heap_page = @import("../../page/slot_heap.zig");
const slots = @import("../../slots/slots.zig");
const fsm = @import("../../storage/fsm/fsm.zig");
const low_level_slot_heap = @import("../../storage/slot_heap/slot_heap.zig");

pub const SizeClasses = union(enum) {
    one,
    logarithmic: struct {
        base: u8 = 8,
        minimum_tracked_space: ?u16 = null,
    },
};

fn requireOption(comptime OptionsT: type, comptime name: []const u8) void {
    if (!@hasField(OptionsT, name)) {
        @compileError("Missing pages.slotHeap option: " ++ name);
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
        @compileError("pages.slotHeap options must be a named struct");
    }
    inline for (info.@"struct".fields) |field| {
        if (comptime !isKnownOption(field.name)) {
            @compileError("Unknown pages.slotHeap option: " ++ field.name);
        }
    }

    requireOption(OptionsT, "compare");
    requireOption(OptionsT, "CompareContext");
    requireOption(OptionsT, "comparator_id");
    requireOption(OptionsT, "maximum_key_size");
    requireOption(OptionsT, "maximum_value_size");

    if (@TypeOf(options.CompareContext) != type) {
        @compileError("pages.slotHeap CompareContext must be a type");
    }

    const CompareContextT = options.CompareContext;
    const CompareFn = fn (CompareContextT, []const u8, []const u8) std.math.Order;

    if (@TypeOf(options.compare) != CompareFn) {
        @compileError("pages.slotHeap compare has an invalid signature");
    }

    const comparator_id = unsignedOption(options.comparator_id, u32, "pages.slotHeap comparator_id must fit u32");
    const maximum_key_size = unsignedOption(options.maximum_key_size, usize, "pages.slotHeap maximum_key_size must fit usize");
    const maximum_value_size = unsignedOption(options.maximum_value_size, usize, "pages.slotHeap maximum_value_size must fit usize");
    const maximum_level = if (@hasField(OptionsT, "maximum_level"))
        unsignedOption(options.maximum_level, usize, "pages.slotHeap maximum_level must fit usize")
    else
        32;
    const size_classes: SizeClasses = if (@hasField(OptionsT, "size_classes")) blk: {
        if (@TypeOf(options.size_classes) != SizeClasses) {
            @compileError("pages.slotHeap size_classes must be pages.SlotHeapSizeClasses");
        }
        break :blk options.size_classes;
    } else .{ .logarithmic = .{} };
    if (comparator_id == 0 or maximum_key_size == 0 or maximum_level == 0) {
        @compileError("pages.slotHeap comparator_id, maximum_key_size, and maximum_level must be non-zero");
    }

    const Trait = struct {
        pub const kind_name: []const u8 = "fullaz.slot-heap.paged";
        pub const format_version: u32 = 1;
        pub const page_kind_count: usize = 3;
        pub const page_roles: [page_kind_count][]const u8 = .{ "leaf", "inode", "fsm_slab" };
        pub const CompareContext = CompareContextT;

        pub fn fingerprint(writer: *FingerprintWriter) void {
            writer.writeInt(u32, comparator_id);
            writer.writeInt(usize, maximum_key_size);
            writer.writeInt(usize, maximum_value_size);
            writer.writeInt(usize, maximum_level);
            switch (size_classes) {
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
            const Format = slot_heap_page.SlotHeap(CacheT.Pid, u16, .little);
            const LocationAccessor = slot_heap_page.LeafPageLocationAccessor(CacheT.Pid, u16, .little);
            const minimum_entry_size = slots.Variadic(u16, .little, true).fullSlotSize(maximum_key_size);
            const minimum_tracked_space = std.math.cast(u16, minimum_entry_size) orelse
                @compileError("pages.slotHeap minimum serialized entry must fit u16");

            const PolicyT, const policy, const class_count = switch (size_classes) {
                .one => .{ fsm.size_classes.One, fsm.size_classes.One{}, 1 },
                .logarithmic => |settings| blk: {
                    const configured_minimum = settings.minimum_tracked_space orelse minimum_tracked_space;
                    const value = fsm.size_classes.Logarithmic.init(.{
                        .base = settings.base,
                        .minimum_tracked_space = configured_minimum,
                    }) catch @compileError("pages.slotHeap has invalid logarithmic size_classes settings");
                    break :blk .{ fsm.size_classes.Logarithmic, value, value.count() };
                },
            };

            const ManagerT = SlotHeapManager(
                BackendT,
                Format.Location,
                maximum_level,
                class_count,
            );
            const FsmModelT = fsm.models.paged.slab.Model(
                CacheT,
                ManagerT,
                PolicyT,
                LocationAccessor,
            );
            const FsmT = fsm.Fsm(FsmModelT);
            const ModelT = low_level_slot_heap.models.Paged(
                CacheT,
                ManagerT,
                FsmT,
                options.compare,
                CompareContextT,
            );
            const HeapT = low_level_slot_heap.Heap(ModelT);

            return struct {
                const MutableProxy = struct {
                    const Self = @This();

                    pub const Peek = HeapT.Peek;
                    pub const Error = HeapT.Error || CacheT.Error;

                    heap: *HeapT,
                    cache: *CacheT,
                    transaction_generation: ?u64,

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

                    /// Returned key/value slices borrow a pinned leaf until Peek.deinit().
                    pub fn top(self: *const Self) Self.Error!Peek {
                        return self.heap.top();
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

                    heap: *const HeapT,

                    pub fn count(self: *const @This()) @This().Error!u64 {
                        return self.heap.count();
                    }

                    pub fn isEmpty(self: *const @This()) @This().Error!bool {
                        return self.heap.isEmpty();
                    }
                };

                pub const Manager = ManagerT;
                pub const FsmModel = FsmModelT;
                pub const Model = ModelT;
                pub const Heap = HeapT;
                pub const Proxy = MutableProxy;
                pub const ConstProxy = ReadProxy;
                pub const InitOptions = if (CompareContextT == void) struct {
                    compare_context: void = {},
                } else struct {
                    compare_context: CompareContextT,
                };
                pub const TransactionState = ManagerT.State;
                pub const Error = HeapT.Error || error{InvalidPageKinds};
                pub const Runtime = struct {
                    cache: *CacheT,
                    manager: ManagerT,
                    fsm_model: FsmModelT,
                    fsm: FsmT,
                    model: ModelT,
                    heap: HeapT,
                    const_proxy: ConstProxy,
                };
                pub const StaticMetadata = struct {
                    const PackedPageId = PackedInt(CacheT.Pid, .little);
                    const PackedCount = PackedInt(u64, .little);

                    pub const Storage = extern struct {
                        root: PackedPageId,
                        cached_top: PackedPageId,
                        entries_count: PackedCount,
                        available_inode_heads: [maximum_level + 1]PackedPageId,
                        fsm_class_roots: [class_count]PackedPageId,
                    };
                    pub const Error = error{BadMetadata};

                    pub fn capture(runtime: *const Runtime) Storage {
                        const state = runtime.manager.getState();
                        var storage: Storage = undefined;
                        storage.root = PackedPageId.init(state.root orelse 0);
                        storage.cached_top = PackedPageId.init(if (state.cached_top) |top| top.page_id else 0);
                        storage.entries_count = PackedCount.init(state.entries_count);
                        inline for (state.available_inode_heads, 0..) |head, index| {
                            storage.available_inode_heads[index] = PackedPageId.init(head orelse 0);
                        }
                        inline for (state.fsm_class_roots, 0..) |root, index| {
                            storage.fsm_class_roots[index] = PackedPageId.init(root orelse 0);
                        }
                        return storage;
                    }

                    pub fn restore(runtime: *Runtime, storage: *const Storage) void {
                        var state: ManagerT.State = .{};
                        state.root = decode(storage.root.get());
                        const top = decode(storage.cached_top.get());
                        state.cached_top = if (top) |page_id| .{ .page_id = page_id, .slot_id = 0 } else null;
                        state.entries_count = storage.entries_count.get();
                        inline for (&state.available_inode_heads, 0..) |*head, index| {
                            head.* = decode(storage.available_inode_heads[index].get());
                        }
                        inline for (&state.fsm_class_roots, 0..) |*root, index| {
                            root.* = decode(storage.fsm_class_roots[index].get());
                        }
                        runtime.manager.restoreState(state);
                    }

                    pub fn validate(storage: *const Storage, page_count: usize) @This().Error!void {
                        try validatePageId(storage.root.get(), page_count);
                        try validatePageId(storage.cached_top.get(), page_count);
                        inline for (storage.available_inode_heads) |head| {
                            try validatePageId(head.get(), page_count);
                        }
                        inline for (storage.fsm_class_roots) |root| {
                            try validatePageId(root.get(), page_count);
                        }
                    }

                    fn decode(page_id: CacheT.Pid) ?CacheT.Pid {
                        return if (page_id == 0) null else page_id;
                    }

                    fn validatePageId(page_id: CacheT.Pid, page_count: usize) @This().Error!void {
                        if (page_id == 0) {
                            return;
                        }
                        const index = std.math.cast(usize, page_id) orelse return @This().Error.BadMetadata;
                        if (index >= page_count) {
                            return @This().Error.BadMetadata;
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

                    const leaf_kind = page_kinds.kindAt(0) orelse return Error.InvalidPageKinds;
                    const inode_kind = page_kinds.kindAt(1) orelse return Error.InvalidPageKinds;
                    const slab_kind = page_kinds.kindAt(2) orelse return Error.InvalidPageKinds;

                    runtime.cache = backend.cache();
                    runtime.manager = ManagerT.init(backend);
                    runtime.fsm_model = FsmModelT.init(backend.cache(), &runtime.manager, policy, .{ .page_kind = slab_kind });
                    runtime.fsm = FsmT.init(&runtime.fsm_model);
                    runtime.model = try ModelT.init(backend.cache(), &runtime.manager, &runtime.fsm, .{ .key_size = maximum_key_size, .maximum_value_size = maximum_value_size, .comparator_id = comparator_id, .leaf_page_kind = leaf_kind, .inode_page_kind = inode_kind, .maximum_level = maximum_level }, init_options.compare_context);
                    runtime.heap = HeapT.init(&runtime.model);
                    runtime.const_proxy = .{ .heap = &runtime.heap };
                }

                pub fn deinitRuntime(runtime: *Runtime) void {
                    runtime.* = undefined;
                }
                pub fn captureTransactionState(runtime: *const Runtime) TransactionState {
                    return runtime.manager.getState();
                }
                pub fn restoreTransactionState(runtime: *Runtime, state: TransactionState) void {
                    runtime.manager.restoreState(state);
                }
                pub fn proxy(runtime: *Runtime) Proxy {
                    return .{
                        .heap = &runtime.heap,
                        .cache = runtime.cache,
                        .transaction_generation = runtime.cache.transactionGeneration(),
                    };
                }
                pub fn proxyConst(runtime: *const Runtime) *const ConstProxy {
                    return &runtime.const_proxy;
                }
            };
        }
    };
    return component.descriptor(Trait);
}
