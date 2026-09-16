const std = @import("std");
const component = @import("../component/component.zig");
const FingerprintWriter = @import("../component/fingerprint.zig").Writer;
const managers = @import("../component/managers/managers.zig");
const dynamic_metadata = @import("../file/metadata/dynamic.zig");
const tagged = @import("../file/tagged_fields.zig");
const fullaz = @import("fullaz");
const gc = fullaz.gc;
const slot_chain = fullaz.storage.slot_chain;
const slot_queue = fullaz.storage.slot_queue;
const slot_stack = fullaz.storage.slot_stack;

const SequenceKind = enum {
    list,
    queue,
    stack,
};

pub fn slotList(comptime options: anytype) component.Descriptor {
    return slotSequence(.list, options);
}

pub fn slotQueue(comptime options: anytype) component.Descriptor {
    return slotSequence(.queue, options);
}

pub fn slotStack(comptime options: anytype) component.Descriptor {
    return slotSequence(.stack, options);
}

fn requireOption(comptime OptionsT: type, comptime name: []const u8) void {
    if (!@hasField(OptionsT, name)) {
        @compileError("Missing fullaz-db slot-sequence option: " ++ name);
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

fn slotSequence(
    comptime sequence_kind: SequenceKind,
    comptime options: anytype,
) component.Descriptor {
    @setEvalBranchQuota(30_000);

    const OptionsT = @TypeOf(options);
    const options_info = @typeInfo(OptionsT);
    if (options_info != .@"struct" or options_info.@"struct".is_tuple) {
        @compileError("fullaz-db slot-sequence options must be a named struct");
    }
    inline for (options_info.@"struct".fields) |field| {
        if (!std.mem.eql(u8, field.name, "maximum_value_size")) {
            @compileError("Unknown fullaz-db slot-sequence option: " ++ field.name);
        }
    }
    requireOption(OptionsT, "maximum_value_size");

    const configured_maximum_value_size = unsignedOption(
        options.maximum_value_size,
        usize,
        "fullaz-db slot-sequence maximum_value_size must fit usize",
    );
    if (configured_maximum_value_size == 0) {
        @compileError("fullaz-db slot-sequence maximum_value_size must be non-zero");
    }
    if (configured_maximum_value_size > std.math.maxInt(u16)) {
        @compileError("fullaz-db slot-sequence maximum_value_size must fit u16");
    }
    const durable_maximum_value_size = std.math.cast(
        u64,
        configured_maximum_value_size,
    ) orelse @compileError("fullaz-db slot-sequence maximum_value_size must fit u64");

    const Trait = struct {
        pub const kind_name: []const u8 = switch (sequence_kind) {
            .list => "fullaz.slot-list.paged",
            .queue => "fullaz.slot-queue.paged",
            .stack => "fullaz.slot-stack.paged",
        };
        pub const format_version: u32 = 1;
        pub const page_kind_count: usize = 1;
        pub const page_roles: [page_kind_count][]const u8 = .{"chunk"};
        pub const maximum_value_size: usize = configured_maximum_value_size;

        pub fn fingerprint(writer: *FingerprintWriter) void {
            writer.writeInt(u64, durable_maximum_value_size);
        }

        pub fn Binding(comptime BackendT: type) type {
            const CacheT = BackendT.CacheType;
            const StateT = slot_chain.State(CacheT.Pid, u64, CacheT.Pid, .little);
            const ManagerT = managers.StateManager(BackendT, StateT);
            const ImplT = SequenceImplementation(
                sequence_kind,
                BackendT,
                ManagerT,
                configured_maximum_value_size,
            );

            const BindingT = struct {
                pub const Manager = ManagerT;
                pub const State = StateT;
                pub const Proxy = ImplT.Proxy;
                pub const ConstProxy = ImplT.ConstProxy;
                pub const InitOptions = struct {};
                pub const TransactionState = StateT;
                pub const Error = ImplT.Error;
                pub const value_capacity: ?usize = configured_maximum_value_size;

                pub const Runtime = struct {
                    state: StateT,
                    manager: ManagerT,
                    sequence: ImplT.Runtime,
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

                    pub fn validate(
                        storage: *const Storage,
                        page_count: usize,
                    ) @This().Error!void {
                        const first_is_nil = storage.page_chain.first.isMax();
                        const last_is_nil = storage.page_chain.last.isMax();
                        if (first_is_nil != last_is_nil) {
                            return error.BadMetadata;
                        }
                        if (first_is_nil) {
                            if (storage.elements_count.get() != 0 or
                                storage.tombstone_count.get() != 0)
                            {
                                return error.BadMetadata;
                            }
                            return;
                        }
                        const elements_count = storage.elements_count.get();
                        if (elements_count == 0 or
                            storage.tombstone_count.get() > elements_count)
                        {
                            return error.BadMetadata;
                        }

                        const first_index = std.math.cast(
                            usize,
                            storage.page_chain.first.get(),
                        ) orelse return error.BadMetadata;
                        const last_index = std.math.cast(
                            usize,
                            storage.page_chain.last.get(),
                        ) orelse return error.BadMetadata;
                        if (first_index >= page_count or last_index >= page_count) {
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

                    pub fn encodeKnown(
                        runtime: *const Runtime,
                        writer: *tagged.Writer,
                    ) @This().Error!void {
                        try writer.append(known_tags[0], 0, std.mem.asBytes(&runtime.state));
                    }
                };

                pub fn Gc(comptime CollectorT: type) type {
                    if (CollectorT.PageId != CacheT.Pid) {
                        @compileError(
                            "fullaz-db slot-sequence GC collector PageId must match CacheType.Pid",
                        );
                    }
                    return struct {
                        pub const RootsError = std.mem.Allocator.Error;
                        pub const RegisterError = CollectorT.Error;
                        const chunk_scanner_version: CollectorT.ScannerVersion = 1;

                        pub fn appendRoots(
                            runtime: *const Runtime,
                            allocator: std.mem.Allocator,
                            roots: *std.ArrayList(CollectorT.PageId),
                        ) RootsError!void {
                            if (!runtime.state.page_chain.first.isMax()) {
                                try roots.append(
                                    allocator,
                                    runtime.state.page_chain.first.get(),
                                );
                            }
                        }

                        pub fn registerScanners(
                            runtime: *const Runtime,
                            collector: *CollectorT,
                        ) RegisterError!void {
                            const chunk_page_kind = runtime.sequence.page_kinds.kindAt(0) orelse
                                unreachable;
                            try collector.registerForCycle(
                                chunk_page_kind,
                                chunk_scanner_version,
                                &runtime.sequence.sequence,
                                gc.scanners.method(
                                    CollectorT,
                                    ImplT.Sequence,
                                    ImplT.Sequence.scanChunkRefs,
                                ),
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
                    runtime.state = .{};
                    runtime.manager = ManagerT.init(backend, &runtime.state);
                    try ImplT.initRuntime(
                        &runtime.sequence,
                        backend,
                        &runtime.manager,
                        page_kinds,
                    );
                }

                pub fn deinitRuntime(runtime: *Runtime) void {
                    ImplT.deinitRuntime(&runtime.sequence);
                    runtime.* = undefined;
                }

                pub fn requireTransactionIdle(runtime: *const Runtime) Error!void {
                    return ImplT.requireTransactionIdle(&runtime.sequence);
                }

                pub fn reclaimPersistent(runtime: *Runtime) Error!void {
                    return ImplT.reclaimPersistent(&runtime.sequence);
                }

                pub fn captureTransactionState(runtime: *const Runtime) TransactionState {
                    return runtime.state;
                }

                pub fn restoreTransactionState(
                    runtime: *Runtime,
                    state: TransactionState,
                ) void {
                    runtime.state = state;
                }

                pub fn proxy(runtime: *Runtime) Proxy {
                    return ImplT.proxy(&runtime.sequence);
                }

                pub fn proxyConst(runtime: *const Runtime) *const ConstProxy {
                    return ImplT.proxyConst(&runtime.sequence);
                }

                pub fn StorageBinding(comptime StorageManagerT: type) type {
                    const StorageImplT = SequenceImplementation(
                        sequence_kind,
                        BackendT,
                        StorageManagerT,
                        configured_maximum_value_size,
                    );

                    const StorageBindingT = struct {
                        const Self = @This();
                        const StorageRuntimeT = StorageImplT.Runtime;

                        pub const State = StateT;
                        pub const Proxy = StorageImplT.Proxy;
                        pub const ConstProxy = StorageImplT.ConstProxy;
                        pub const InitOptions = struct {};
                        pub const Error = StorageImplT.Error;
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
                            _: Self.InitOptions,
                        ) Self.Error!void {
                            return StorageImplT.initRuntime(
                                runtime,
                                backend,
                                storage_manager,
                                page_kinds,
                            );
                        }

                        pub fn deinitRuntime(runtime: *StorageRuntimeT) void {
                            StorageImplT.deinitRuntime(runtime);
                        }

                        pub fn requireTransactionIdle(runtime: *const StorageRuntimeT) Self.Error!void {
                            return StorageImplT.requireTransactionIdle(runtime);
                        }

                        pub fn reclaimPersistent(runtime: *StorageRuntimeT) Self.Error!void {
                            return StorageImplT.reclaimPersistent(runtime);
                        }

                        pub fn proxy(runtime: *StorageRuntimeT) Self.Proxy {
                            return StorageImplT.proxy(runtime);
                        }

                        pub fn proxyConst(runtime: *const StorageRuntimeT) *const Self.ConstProxy {
                            return StorageImplT.proxyConst(runtime);
                        }
                    };
                    comptime component.assertStorageBinding(
                        StorageBindingT,
                        BackendT,
                        StorageManagerT,
                        StateT,
                    );
                    return StorageBindingT;
                }
            };
            comptime component.assertDynamicMetadata(BindingT, BindingT.DynamicMetadata);
            comptime component.assertBinding(BindingT, BackendT);
            comptime component.assertReclamation(BindingT);
            comptime component.assertStorageBinding(
                BindingT.StorageBinding(ManagerT),
                BackendT,
                ManagerT,
                StateT,
            );
            return BindingT;
        }
    };
    return component.descriptor(Trait);
}

fn SequenceImplementation(
    comptime sequence_kind: SequenceKind,
    comptime BackendT: type,
    comptime StorageManagerT: type,
    comptime maximum_value_size: usize,
) type {
    const maximum_value_size_v = maximum_value_size;
    const CacheT = BackendT.CacheType;
    const StateT = slot_chain.State(CacheT.Pid, u64, CacheT.Pid, .little);
    const ChainT = switch (sequence_kind) {
        .list => slot_chain.Handle(
            CacheT,
            StorageManagerT,
            u64,
            CacheT.Pid,
            .little,
        ),
        .queue => slot_chain.ForwardHandle(
            CacheT,
            StorageManagerT,
            u64,
            CacheT.Pid,
            .little,
        ),
        .stack => slot_chain.BidirectionalHandle(
            CacheT,
            StorageManagerT,
            u64,
            CacheT.Pid,
            .little,
        ),
    };
    const SequenceT = switch (sequence_kind) {
        .list => ChainT,
        .queue => slot_queue.SlotQueue(
            CacheT,
            StorageManagerT,
            u64,
            CacheT.Pid,
            .little,
        ),
        .stack => slot_stack.SlotStack(
            CacheT,
            StorageManagerT,
            u64,
            CacheT.Pid,
            .little,
        ),
    };
    const LowPeekT = if (sequence_kind == .list) void else SequenceT.Peek;
    const ReadError = ChainT.Error || SequenceT.Error;
    const minimum_page_size = ChainT.View.PageView.header_size +
        @sizeOf(u16) * 5 +
        ChainT.View.SlotsDir.fullSlotSize(maximum_value_size_v);
    const ErrorSet = ReadError || CacheT.Error || error{
        InvalidPageKinds,
        IteratorActive,
        PeekActive,
        UnsupportedPageSize,
        ValueTooLarge,
    };

    comptime {
        if (minimum_page_size > std.math.maxInt(u16)) {
            @compileError("fullaz-db slot-sequence maximum_value_size does not fit a SlotChain page");
        }
        if (ChainT.StateType != StateT or SequenceT.StateType != StateT) {
            @compileError("fullaz-db slot-sequence low-level state type mismatch");
        }
    }

    return struct {
        const ImplSelf = @This();

        pub const Error = ErrorSet;
        pub const Sequence = SequenceT;

        pub const Runtime = struct {
            page_kinds: component.PageKindRange,
            cache: *CacheT,
            storage_manager: *StorageManagerT,
            sequence: SequenceT,
            const_proxy: ConstProxy,
            active_iterators: usize = 0,
            active_peeks: usize = 0,
            active_editor: bool = false,
        };

        pub const ValueEditor = struct {
            const Self = @This();

            pub const Error = ErrorSet;

            editor: ChainT.ValueEditor,
            cache: *CacheT,
            active_editor: *bool,
            transaction_generation: ?u64,
            open: bool = true,

            fn requireTransaction(self: *const Self) Self.Error!void {
                if (!self.open) {
                    return error.EditorInvalidated;
                }
                if (self.transaction_generation == null or
                    self.cache.transactionGeneration() != self.transaction_generation)
                {
                    return error.TransactionInactive;
                }
            }

            pub fn valueMut(self: *Self) Self.Error![]u8 {
                try self.requireTransaction();
                return self.editor.valueMut();
            }

            pub fn originalValue(self: *const Self) Self.Error![]const u8 {
                try self.requireTransaction();
                return self.editor.originalValue();
            }

            pub fn finish(self: *Self) Self.Error!void {
                try self.requireTransaction();
                self.editor.finish() catch |err| {
                    switch (err) {
                        error.ValueEditorActive,
                        error.StructuralMutationActive,
                        error.StaleIterator,
                        error.EditorInvalidated,
                        => {},
                        else => self.cache.markTransactionFailed(),
                    }
                    return err;
                };
                self.active_editor.* = false;
                self.open = false;
            }

            pub fn deinit(self: *Self) void {
                if (!self.open) {
                    return;
                }
                self.editor.deinit();
                self.active_editor.* = false;
                self.open = false;
            }
        };

        pub const MutableIterator = struct {
            const Self = @This();

            pub const Error = ErrorSet;

            inner: ChainT.Iterator,
            cache: *CacheT,
            active_iterators: *usize,
            active_editor: *bool,
            transaction_generation: ?u64,
            open: bool = true,

            fn requireTransaction(self: *const Self) Self.Error!void {
                if (!self.open) {
                    return error.InvalidIterator;
                }
                if (self.transaction_generation == null or
                    self.cache.transactionGeneration() != self.transaction_generation)
                {
                    return error.TransactionInactive;
                }
            }

            /// The returned slice is valid until the iterator advances or is deinitialized.
            pub fn next(self: *Self) Self.Error!?[]const u8 {
                try self.requireTransaction();
                const result = if (comptime sequence_kind == .stack)
                    try self.inner.prev()
                else
                    try self.inner.next();
                return if (result) |value| value.value else null;
            }

            pub fn markTombstone(self: *Self) Self.Error!void {
                try self.requireTransaction();
                if (self.active_editor.*) {
                    return error.ValueEditorActive;
                }
                self.inner.markTombstone() catch |err| {
                    self.cache.markTransactionFailed();
                    return err;
                };
            }

            pub fn editValue(self: *Self) Self.Error!?ValueEditor {
                try self.requireTransaction();
                if (self.active_editor.*) {
                    return error.ValueEditorActive;
                }
                const editor = (try self.inner.editValue()) orelse return null;
                self.active_editor.* = true;
                return .{
                    .editor = editor,
                    .cache = self.cache,
                    .active_editor = self.active_editor,
                    .transaction_generation = self.transaction_generation,
                };
            }

            pub fn deinit(self: *Self) void {
                if (!self.open) {
                    return;
                }
                self.inner.deinit();
                std.debug.assert(self.active_iterators.* != 0);
                self.active_iterators.* -= 1;
                self.open = false;
            }
        };

        pub const ReadIterator = struct {
            const Self = @This();

            inner: ChainT.Iterator,
            active_iterators: *usize,
            open: bool = true,

            /// The returned slice is valid until the iterator advances or is deinitialized.
            pub fn next(self: *Self) ReadError!?[]const u8 {
                if (!self.open) {
                    return error.InvalidIterator;
                }
                const result = if (comptime sequence_kind == .stack)
                    try self.inner.prev()
                else
                    try self.inner.next();
                return if (result) |value| value.value else null;
            }

            pub fn deinit(self: *Self) void {
                if (!self.open) {
                    return;
                }
                self.inner.deinit();
                std.debug.assert(self.active_iterators.* != 0);
                self.active_iterators.* -= 1;
                self.open = false;
            }
        };

        pub const MutablePeek = struct {
            const Self = @This();

            pub const Error = ErrorSet;

            inner: LowPeekT,
            cache: *CacheT,
            active_peeks: *usize,
            active_editor: *bool,
            transaction_generation: ?u64,
            open: bool = true,

            fn requireTransaction(self: *const Self) Self.Error!void {
                if (!self.open) {
                    return error.InvalidIterator;
                }
                if (self.transaction_generation == null or
                    self.cache.transactionGeneration() != self.transaction_generation)
                {
                    return error.TransactionInactive;
                }
            }

            /// The returned slice is valid until this peek is deinitialized.
            pub fn value(self: *const Self) Self.Error![]const u8 {
                if (comptime sequence_kind == .list) {
                    @compileError("slot-list does not support peeking");
                }
                try self.requireTransaction();
                return self.inner.value();
            }

            pub fn editValue(self: *Self) Self.Error!ValueEditor {
                if (comptime sequence_kind == .list) {
                    @compileError("slot-list does not support peeking");
                }
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

            pub fn deinit(self: *Self) void {
                if (!self.open) {
                    return;
                }
                if (comptime sequence_kind != .list) {
                    self.inner.deinit();
                }
                std.debug.assert(self.active_peeks.* != 0);
                self.active_peeks.* -= 1;
                self.open = false;
            }
        };

        pub const ConstPeek = struct {
            const Self = @This();

            inner: LowPeekT,
            active_peeks: *usize,
            open: bool = true,

            /// The returned slice is valid until this peek is deinitialized.
            pub fn value(self: *const Self) ReadError![]const u8 {
                if (comptime sequence_kind == .list) {
                    @compileError("slot-list does not support peeking");
                }
                if (!self.open) {
                    return error.InvalidIterator;
                }
                return self.inner.value();
            }

            pub fn deinit(self: *Self) void {
                if (!self.open) {
                    return;
                }
                if (comptime sequence_kind != .list) {
                    self.inner.deinit();
                }
                std.debug.assert(self.active_peeks.* != 0);
                self.active_peeks.* -= 1;
                self.open = false;
            }
        };

        pub const Proxy = struct {
            const Self = @This();

            pub const Iterator = MutableIterator;
            pub const Peek = MutablePeek;
            pub const Editor = ValueEditor;
            pub const Error = ErrorSet;

            sequence: *SequenceT,
            cache: *CacheT,
            active_iterators: *usize,
            active_peeks: *usize,
            active_editor: *bool,
            transaction_generation: ?u64,

            fn requireTransaction(self: *const Self) Self.Error!void {
                if (self.transaction_generation == null or
                    self.cache.transactionGeneration() != self.transaction_generation)
                {
                    return error.TransactionInactive;
                }
            }

            fn requireStructuralMutation(self: *const Self) Self.Error!void {
                try self.requireTransaction();
                if (self.active_editor.*) {
                    return error.ValueEditorActive;
                }
                if (self.active_peeks.* != 0) {
                    return error.PeekActive;
                }
                if (self.active_iterators.* != 0) {
                    return error.IteratorActive;
                }
            }

            pub fn size(self: *const Self) Self.Error!usize {
                try self.requireTransaction();
                return ImplSelf.liveCount(self.sequence);
            }

            pub fn isEmpty(self: *const Self) Self.Error!bool {
                return (try self.size()) == 0;
            }

            pub fn elementsCount(self: *const Self) Self.Error!usize {
                try self.requireTransaction();
                return ImplSelf.elementsCount(self.sequence);
            }

            pub fn tombstoneCount(self: *const Self) Self.Error!usize {
                try self.requireTransaction();
                return ImplSelf.tombstoneCount(self.sequence);
            }

            pub fn iterator(self: *const Self) Self.Error!?Iterator {
                try self.requireTransaction();
                const inner = (try ImplSelf.openIterator(self.sequence)) orelse return null;
                self.active_iterators.* += 1;
                return .{
                    .inner = inner,
                    .cache = self.cache,
                    .active_iterators = self.active_iterators,
                    .active_editor = self.active_editor,
                    .transaction_generation = self.transaction_generation,
                };
            }

            pub fn removeTombstones(self: *const Self) Self.Error!usize {
                try self.requireStructuralMutation();
                return ImplSelf.chain(self.sequence).removeTombstones() catch |err| {
                    self.cache.markTransactionFailed();
                    return err;
                };
            }

            pub fn append(self: *const Self, value: []const u8) Self.Error!void {
                if (comptime sequence_kind != .list) {
                    @compileError("append is only available on slot-list");
                }
                return self.appendLike(value);
            }

            pub fn enqueue(self: *const Self, value: []const u8) Self.Error!void {
                if (comptime sequence_kind != .queue) {
                    @compileError("enqueue is only available on slot-queue");
                }
                return self.appendLike(value);
            }

            pub fn push(self: *const Self, value: []const u8) Self.Error!void {
                if (comptime sequence_kind != .stack) {
                    @compileError("push is only available on slot-stack");
                }
                return self.appendLike(value);
            }

            pub fn front(self: *const Self) Self.Error!Peek {
                if (comptime sequence_kind != .queue) {
                    @compileError("front is only available on slot-queue");
                }
                return self.openPeek();
            }

            pub fn top(self: *const Self) Self.Error!Peek {
                if (comptime sequence_kind != .stack) {
                    @compileError("top is only available on slot-stack");
                }
                return self.openPeek();
            }

            pub fn dequeue(self: *const Self) Self.Error!void {
                if (comptime sequence_kind != .queue) {
                    @compileError("dequeue is only available on slot-queue");
                }
                try self.requireStructuralMutation();
                self.sequence.dequeue() catch |err| {
                    self.cache.markTransactionFailed();
                    return err;
                };
            }

            pub fn pop(self: *const Self) Self.Error!void {
                if (comptime sequence_kind != .stack) {
                    @compileError("pop is only available on slot-stack");
                }
                try self.requireStructuralMutation();
                self.sequence.pop() catch |err| {
                    self.cache.markTransactionFailed();
                    return err;
                };
            }

            fn appendLike(self: *const Self, value: []const u8) Self.Error!void {
                try self.requireStructuralMutation();
                if (value.len > maximum_value_size_v) {
                    return error.ValueTooLarge;
                }

                const chain_handle = ImplSelf.chain(self.sequence);
                defer chain_handle.releaseCachedTail();
                switch (sequence_kind) {
                    .list => {
                        _ = self.sequence.append(value) catch |err| {
                            self.cache.markTransactionFailed();
                            return err;
                        };
                    },
                    .queue => self.sequence.enqueue(value) catch |err| {
                        self.cache.markTransactionFailed();
                        return err;
                    },
                    .stack => self.sequence.push(value) catch |err| {
                        self.cache.markTransactionFailed();
                        return err;
                    },
                }
            }

            fn openPeek(self: *const Self) Self.Error!Peek {
                try self.requireTransaction();
                const inner = try ImplSelf.openPeek(self.sequence);
                self.active_peeks.* += 1;
                return .{
                    .inner = inner,
                    .cache = self.cache,
                    .active_peeks = self.active_peeks,
                    .active_editor = self.active_editor,
                    .transaction_generation = self.transaction_generation,
                };
            }
        };

        pub const ConstProxy = struct {
            const Self = @This();

            pub const Iterator = ReadIterator;
            pub const Peek = ConstPeek;
            pub const Error = ReadError;

            sequence: *SequenceT,
            active_iterators: *usize,
            active_peeks: *usize,

            pub fn size(self: *const Self) Self.Error!usize {
                return ImplSelf.liveCount(self.sequence);
            }

            pub fn isEmpty(self: *const Self) Self.Error!bool {
                return (try self.size()) == 0;
            }

            pub fn elementsCount(self: *const Self) Self.Error!usize {
                return ImplSelf.elementsCount(self.sequence);
            }

            pub fn tombstoneCount(self: *const Self) Self.Error!usize {
                return ImplSelf.tombstoneCount(self.sequence);
            }

            pub fn iterator(self: *const Self) Self.Error!?Iterator {
                const inner = (try ImplSelf.openIterator(self.sequence)) orelse return null;
                self.active_iterators.* += 1;
                return .{
                    .inner = inner,
                    .active_iterators = self.active_iterators,
                };
            }

            pub fn front(self: *const Self) Self.Error!Peek {
                if (comptime sequence_kind != .queue) {
                    @compileError("front is only available on slot-queue");
                }
                return self.openPeek();
            }

            pub fn top(self: *const Self) Self.Error!Peek {
                if (comptime sequence_kind != .stack) {
                    @compileError("top is only available on slot-stack");
                }
                return self.openPeek();
            }

            fn openPeek(self: *const Self) Self.Error!Peek {
                const inner = try ImplSelf.openPeek(self.sequence);
                self.active_peeks.* += 1;
                return .{
                    .inner = inner,
                    .active_peeks = self.active_peeks,
                };
            }
        };

        fn chain(sequence: *SequenceT) *ChainT {
            return if (comptime sequence_kind == .list)
                sequence
            else
                &sequence.chain;
        }

        fn liveCount(sequence: *SequenceT) ReadError!usize {
            return chain(sequence).size();
        }

        fn elementsCount(sequence: *SequenceT) ReadError!usize {
            return chain(sequence).elementsCount();
        }

        fn tombstoneCount(sequence: *SequenceT) ReadError!usize {
            return chain(sequence).tombstoneCount();
        }

        fn openIterator(sequence: *SequenceT) ReadError!?ChainT.Iterator {
            return if (comptime sequence_kind == .stack)
                chain(sequence).iteratorFromEnd()
            else
                chain(sequence).iterator();
        }

        fn openPeek(sequence: *SequenceT) ReadError!LowPeekT {
            if (comptime sequence_kind == .queue) {
                return sequence.front();
            }
            if (comptime sequence_kind == .stack) {
                return sequence.top();
            }
            @compileError("slot-list does not support peeking");
        }

        pub fn initRuntime(
            runtime: *Runtime,
            backend: *BackendT,
            storage_manager: *StorageManagerT,
            page_kinds: component.PageKindRange,
        ) Error!void {
            if (page_kinds.count != 1) {
                return error.InvalidPageKinds;
            }
            const chunk_page_kind = page_kinds.kindAt(0) orelse
                return error.InvalidPageKinds;

            runtime.page_kinds = page_kinds;
            runtime.cache = backend.cache();
            if (runtime.cache.pageSize() < minimum_page_size or
                runtime.cache.pageSize() > std.math.maxInt(u16))
            {
                return error.UnsupportedPageSize;
            }
            runtime.storage_manager = storage_manager;
            runtime.sequence = try SequenceT.init(
                runtime.cache,
                storage_manager,
                .{ .chunk_page_kind = chunk_page_kind },
            );
            runtime.active_iterators = 0;
            runtime.active_peeks = 0;
            runtime.active_editor = false;
            runtime.const_proxy = .{
                .sequence = &runtime.sequence,
                .active_iterators = &runtime.active_iterators,
                .active_peeks = &runtime.active_peeks,
            };
        }

        pub fn deinitRuntime(runtime: *Runtime) void {
            requireTransactionIdle(runtime) catch
                @panic("slot-sequence runtime deinitialized with active borrowed resources");
            runtime.sequence.deinit();
            runtime.* = undefined;
        }

        pub fn requireTransactionIdle(runtime: *const Runtime) Error!void {
            if (runtime.active_editor) {
                return error.ValueEditorActive;
            }
            if (runtime.active_peeks != 0) {
                return error.PeekActive;
            }
            if (runtime.active_iterators != 0) {
                return error.IteratorActive;
            }
        }

        pub fn reclaimPersistent(runtime: *Runtime) Error!void {
            try requireTransactionIdle(runtime);
            const chain_handle = chain(&runtime.sequence);
            defer chain_handle.releaseCachedTail();

            const MarkAll = struct {
                fn call(
                    _: void,
                    _: ChainT.PageId,
                    _: usize,
                    _: []const u8,
                ) error{}!bool {
                    return true;
                }
            };
            _ = chain_handle.markTombstonesIf({}, MarkAll.call) catch |err| {
                runtime.cache.markTransactionFailed();
                return err;
            };
            _ = chain_handle.removeTombstones() catch |err| {
                runtime.cache.markTransactionFailed();
                return err;
            };
        }

        pub fn proxy(runtime: *Runtime) Proxy {
            return .{
                .sequence = &runtime.sequence,
                .cache = runtime.cache,
                .active_iterators = &runtime.active_iterators,
                .active_peeks = &runtime.active_peeks,
                .active_editor = &runtime.active_editor,
                .transaction_generation = runtime.cache.transactionGeneration(),
            };
        }

        pub fn proxyConst(runtime: *const Runtime) *const ConstProxy {
            return &runtime.const_proxy;
        }
    };
}
