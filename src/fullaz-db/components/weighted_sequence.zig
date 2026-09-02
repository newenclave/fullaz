const std = @import("std");
const component = @import("../component/component.zig");
const FingerprintWriter = @import("../component/fingerprint.zig").Writer;
const managers = @import("../component/managers/managers.zig");
const weighted_bpt = @import("fullaz").weighted_bpt;
const weighted_seq = @import("fullaz").storage.weighted_seq;
const gc = @import("fullaz").gc;
const dynamic_metadata = @import("../file/metadata/dynamic.zig");
const tagged = @import("../file/tagged_fields.zig");

pub fn weightedSequence(comptime options: anytype) component.Descriptor {
    const OptionsT = @TypeOf(options);
    const info = @typeInfo(OptionsT);

    const Offset = u64;

    if (info != .@"struct" or info.@"struct".is_tuple) {
        @compileError("fullaz-db.weightedSequence options must be a named struct");
    }
    inline for (info.@"struct".fields) |field| {
        if (!std.mem.eql(u8, field.name, "maximum_chunk_size")) {
            @compileError("Unknown fullaz-db.weightedSequence option: " ++ field.name);
        }
    }
    const configured_maximum_chunk_size =
        if (@hasField(OptionsT, "maximum_chunk_size")) options.maximum_chunk_size else 256;

    const ChunkSizeT = @TypeOf(configured_maximum_chunk_size);

    switch (@typeInfo(ChunkSizeT)) {
        .int, .comptime_int => {},
        else => @compileError("fullaz-db.weightedSequence maximum_chunk_size must be an unsigned integer"),
    }
    const chunk_size = std.math.cast(usize, configured_maximum_chunk_size) orelse
        @compileError("fullaz-db.weightedSequence maximum_chunk_size must fit usize");
    if (chunk_size == 0) {
        @compileError("fullaz-db.weightedSequence maximum_chunk_size must be non-zero");
    }

    const Trait = struct {
        pub const kind_name: []const u8 = "fullaz.weighted-sequence.paged";
        pub const format_version: u32 = 2;
        pub const page_kind_count: usize = 2;
        pub const page_roles: [page_kind_count][]const u8 = .{ "leaf", "inode" };
        pub const maximum_chunk_size: usize = chunk_size;

        pub fn fingerprint(writer: *FingerprintWriter) void {
            writer.writeInt(u64, @intCast(chunk_size));
        }

        pub fn Binding(comptime BackendT: type) type {
            const CacheT = BackendT.CacheType;
            const StateT = weighted_bpt.models.paged.State(CacheT.Pid);
            const ManagerT = managers.StateManager(BackendT, StateT);
            const ModelT = weighted_bpt.models.paged.PagedModel(
                CacheT,
                ManagerT,
                u64,
                void,
            );
            const TreeT = weighted_bpt.WeightedBpt(ModelT);
            const SequenceT = weighted_seq.WeightedSeq(TreeT, chunk_size);
            const BindingError = SequenceT.Error || error{InvalidPageKinds};

            const ProxyT = struct {
                const Self = @This();
                pub const Error = SequenceT.Error || CacheT.Error;

                sequence: *SequenceT,
                cache: *CacheT,
                transaction_generation: ?u64,

                fn requireTransaction(self: *const Self) Self.Error!void {
                    if (self.transaction_generation == null or
                        self.cache.transactionGeneration() != self.transaction_generation)
                    {
                        return Self.Error.TransactionInactive;
                    }
                }

                pub fn size(self: *const Self) Self.Error!u64 {
                    return self.sequence.size();
                }

                pub fn readAt(self: *const Self, offset: Offset, out: []u8) Self.Error!usize {
                    return self.sequence.readAt(offset, out);
                }

                pub fn insert(self: *const Self, offset: Offset, bytes: []const u8) Self.Error!void {
                    try self.requireTransaction();
                    self.sequence.insert(offset, bytes) catch |err| {
                        self.cache.markTransactionFailed();
                        return err;
                    };
                }

                pub fn append(self: *const Self, bytes: []const u8) Self.Error!void {
                    try self.insert(try self.size(), bytes);
                }

                pub fn erase(self: *const Self, offset: Offset, len: Offset) Self.Error!void {
                    try self.requireTransaction();
                    self.sequence.erase(offset, len) catch |err| {
                        self.cache.markTransactionFailed();
                        return err;
                    };
                }

                pub fn replace(self: *const Self, offset: Offset, len: Offset, bytes: []const u8) Self.Error!void {
                    try self.requireTransaction();
                    self.sequence.replace(offset, len, bytes) catch |err| {
                        self.cache.markTransactionFailed();
                        return err;
                    };
                }

                pub fn clear(self: *const Self) Self.Error!void {
                    try self.requireTransaction();
                    self.sequence.clear() catch |err| {
                        self.cache.markTransactionFailed();
                        return err;
                    };
                }
            };

            const ConstProxyT = struct {
                const Self = @This();

                pub const Error = SequenceT.Error;
                sequence: *SequenceT,

                pub fn size(self: *const Self) @This().Error!Offset {
                    return self.sequence.size();
                }

                pub fn readAt(self: *const Self, offset: u64, out: []u8) @This().Error!usize {
                    return self.sequence.readAt(offset, out);
                }
            };

            const BindingT = struct {
                pub const Manager = ManagerT;
                pub const State = StateT;
                pub const value_capacity: ?usize = null;
                pub const Proxy = ProxyT;
                pub const ConstProxy = ConstProxyT;
                pub const InitOptions = struct {};
                pub const TransactionState = StateT;
                pub const Error = BindingError;

                pub const Runtime = struct {
                    page_kinds: component.PageKindRange,
                    state: StateT,
                    manager: ManagerT,
                    model: ModelT,
                    tree: TreeT,
                    sequence: SequenceT,
                    const_proxy: ConstProxy,
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
                        if (storage.root.isMax()) {
                            return;
                        }
                        const root = storage.root.get();
                        if ((std.math.cast(usize, root) orelse return error.BadMetadata) >= page_count) {
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
                        @compileError("fullaz-db WeightedSequence GC collector PageId must match CacheType.Pid");
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
                                &runtime.sequence,
                                gc.scanners.method(CollectorT, SequenceT, SequenceT.scanLeafRefs),
                                null,
                            );
                            try collector.registerForCycle(
                                inode_page_kind,
                                inode_scanner_version,
                                &runtime.sequence,
                                gc.scanners.method(CollectorT, SequenceT, SequenceT.scanInodeRefs),
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
                ) BindingError!void {
                    if (page_kinds.count != page_kind_count) {
                        return error.InvalidPageKinds;
                    }
                    const leaf_kind = page_kinds.kindAt(0) orelse return error.InvalidPageKinds;
                    const inode_kind = page_kinds.kindAt(1) orelse return error.InvalidPageKinds;
                    runtime.page_kinds = page_kinds;
                    runtime.state = .{};
                    runtime.manager = ManagerT.init(backend, &runtime.state);
                    runtime.model = ModelT.init(backend.cache(), &runtime.manager, .{
                        .maximum_value_size = chunk_size,
                        .leaf_page_kind = leaf_kind,
                        .inode_page_kind = inode_kind,
                    });
                    runtime.tree = TreeT.init(&runtime.model, .neighbor_share);
                    runtime.sequence = SequenceT.init(&runtime.tree);
                    runtime.const_proxy = .{ .sequence = &runtime.sequence };
                }

                pub fn deinitRuntime(runtime: *Runtime) void {
                    runtime.tree.deinit();
                    runtime.model.deinit();
                    runtime.* = undefined;
                }

                pub fn requireTransactionIdle(_: *const Runtime) BindingError!void {}

                pub fn reclaimPersistent(runtime: *Runtime) BindingError!void {
                    try runtime.sequence.clear();
                }

                pub fn captureTransactionState(runtime: *const Runtime) TransactionState {
                    return runtime.state;
                }

                pub fn restoreTransactionState(runtime: *Runtime, state: TransactionState) void {
                    runtime.state = state;
                }

                pub fn proxy(runtime: *Runtime) Proxy {
                    return .{
                        .sequence = &runtime.sequence,
                        .cache = runtime.manager.cache_ptr,
                        .transaction_generation = runtime.manager.cache_ptr.transactionGeneration(),
                    };
                }

                pub fn proxyConst(runtime: *const Runtime) *const ConstProxy {
                    return &runtime.const_proxy;
                }

                pub fn StorageBinding(comptime StorageManagerT: type) type {
                    const StorageModelT = weighted_bpt.models.paged.PagedModel(
                        CacheT,
                        StorageManagerT,
                        u64,
                        void,
                    );
                    const StorageTreeT = weighted_bpt.WeightedBpt(StorageModelT);
                    const StorageSequenceT = weighted_seq.WeightedSeq(StorageTreeT, chunk_size);
                    const StorageInitOptionsT = struct {};
                    const StorageError = StorageSequenceT.Error || error{InvalidPageKinds};

                    const StorageProxyT = struct {
                        const Self = @This();

                        pub const Error = StorageSequenceT.Error || CacheT.Error;

                        sequence: *StorageSequenceT,
                        cache: *CacheT,
                        transaction_generation: ?u64,

                        fn requireTransaction(self: *const Self) Self.Error!void {
                            if (self.transaction_generation == null or
                                self.cache.transactionGeneration() != self.transaction_generation)
                            {
                                return Self.Error.TransactionInactive;
                            }
                        }

                        pub fn size(self: *const Self) Self.Error!u64 {
                            return self.sequence.size();
                        }

                        pub fn readAt(self: *const Self, offset: Offset, out: []u8) Self.Error!usize {
                            return self.sequence.readAt(offset, out);
                        }

                        pub fn insert(self: *const Self, offset: Offset, bytes: []const u8) Self.Error!void {
                            try self.requireTransaction();
                            self.sequence.insert(offset, bytes) catch |err| {
                                self.cache.markTransactionFailed();
                                return err;
                            };
                        }

                        pub fn append(self: *const Self, bytes: []const u8) Self.Error!void {
                            try self.insert(try self.size(), bytes);
                        }

                        pub fn erase(self: *const Self, offset: Offset, len: Offset) Self.Error!void {
                            try self.requireTransaction();
                            self.sequence.erase(offset, len) catch |err| {
                                self.cache.markTransactionFailed();
                                return err;
                            };
                        }

                        pub fn replace(self: *const Self, offset: Offset, len: Offset, bytes: []const u8) Self.Error!void {
                            try self.requireTransaction();
                            self.sequence.replace(offset, len, bytes) catch |err| {
                                self.cache.markTransactionFailed();
                                return err;
                            };
                        }

                        pub fn clear(self: *const Self) Self.Error!void {
                            try self.requireTransaction();
                            self.sequence.clear() catch |err| {
                                self.cache.markTransactionFailed();
                                return err;
                            };
                        }
                    };

                    const StorageConstProxyT = struct {
                        const Self = @This();

                        pub const Error = StorageSequenceT.Error;

                        sequence: *StorageSequenceT,

                        pub fn size(self: *const Self) Self.Error!Offset {
                            return self.sequence.size();
                        }

                        pub fn readAt(self: *const Self, offset: u64, out: []u8) Self.Error!usize {
                            return self.sequence.readAt(offset, out);
                        }
                    };

                    const StorageRuntimeT = struct {
                        page_kinds: component.PageKindRange,
                        cache: *CacheT,
                        manager: *StorageManagerT,
                        model: StorageModelT,
                        tree: StorageTreeT,
                        sequence: StorageSequenceT,
                        const_proxy: StorageConstProxyT,
                    };

                    const StorageBindingT = struct {
                        pub const Runtime = StorageRuntimeT;
                        pub const Proxy = StorageProxyT;
                        pub const ConstProxy = StorageConstProxyT;
                        pub const InitOptions = StorageInitOptionsT;
                        pub const Error = StorageError;
                        pub const value_capacity: ?usize = null;

                        pub fn emptyState() StateT {
                            return .{};
                        }

                        pub fn initRuntime(
                            runtime: *StorageRuntimeT,
                            backend: *BackendT,
                            manager: *StorageManagerT,
                            page_kinds: component.PageKindRange,
                            _: StorageInitOptionsT,
                        ) StorageError!void {
                            if (page_kinds.count != page_kind_count) {
                                return error.InvalidPageKinds;
                            }
                            const leaf_kind = page_kinds.kindAt(0) orelse return error.InvalidPageKinds;
                            const inode_kind = page_kinds.kindAt(1) orelse return error.InvalidPageKinds;

                            runtime.page_kinds = page_kinds;
                            runtime.cache = backend.cache();
                            runtime.manager = manager;
                            runtime.model = StorageModelT.init(runtime.cache, manager, .{
                                .maximum_value_size = chunk_size,
                                .leaf_page_kind = leaf_kind,
                                .inode_page_kind = inode_kind,
                            });
                            runtime.tree = StorageTreeT.init(&runtime.model, .neighbor_share);
                            runtime.sequence = StorageSequenceT.init(&runtime.tree);
                            runtime.const_proxy = .{ .sequence = &runtime.sequence };
                        }

                        pub fn deinitRuntime(runtime: *StorageRuntimeT) void {
                            runtime.tree.deinit();
                            runtime.model.deinit();
                            runtime.* = undefined;
                        }

                        pub fn requireTransactionIdle(_: *const StorageRuntimeT) StorageError!void {}

                        pub fn proxy(runtime: *StorageRuntimeT) StorageProxyT {
                            return .{
                                .sequence = &runtime.sequence,
                                .cache = runtime.cache,
                                .transaction_generation = runtime.cache.transactionGeneration(),
                            };
                        }

                        pub fn proxyConst(runtime: *const StorageRuntimeT) *const StorageConstProxyT {
                            return &runtime.const_proxy;
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
