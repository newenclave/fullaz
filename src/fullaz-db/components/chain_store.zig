const std = @import("std");
const component = @import("../component/component.zig");
const FingerprintWriter = @import("../component/fingerprint.zig").Writer;
const managers = @import("../component/managers/managers.zig");
const low_level_chain_store = @import("fullaz").storage.chain_store;
const gc = @import("fullaz").gc;
const dynamic_metadata = @import("../file/metadata/dynamic.zig");
const tagged = @import("../file/tagged_fields.zig");

pub fn chainStore(comptime options: anytype) component.Descriptor {
    const OptionsT = @TypeOf(options);
    const info = @typeInfo(OptionsT);
    if (info != .@"struct" or info.@"struct".fields.len != 0) {
        @compileError("fullaz-db.chainStore options must be an empty struct");
    }

    const Trait = struct {
        pub const kind_name: []const u8 = "fullaz.chain-store.paged";
        pub const format_version: u32 = 2;
        pub const page_kind_count: usize = 1;
        pub const page_roles: [page_kind_count][]const u8 = .{"chunk"};

        pub fn fingerprint(_: *FingerprintWriter) void {}

        pub fn Binding(comptime BackendT: type) type {
            const CacheT = BackendT.CacheType;
            const StateT = low_level_chain_store.State(CacheT.Pid, u64, .little);
            const StateManagerT = managers.StateManager(BackendT, StateT);
            const ManagerT = struct {
                const Self = @This();

                pub const PageId = CacheT.Pid;
                pub const Size = u64;
                pub const Error = StateManagerT.Error;
                pub const StateLeaseType = StateManagerT.StateLeaseType;

                inner: StateManagerT,

                pub fn init(backend: *BackendT, state_ptr: *StateT) Self {
                    return .{ .inner = StateManagerT.init(backend, state_ptr) };
                }

                pub fn state(self: *Self) Error!StateLeaseType {
                    return self.inner.state();
                }

                pub fn destroyPage(self: *Self, page_id: PageId) Error!void {
                    return self.inner.destroyPage(page_id);
                }
            };
            const BlobT = low_level_chain_store.Blob(
                CacheT,
                ManagerT,
                .little,
            );
            const BindingError = BlobT.Error || error{InvalidPageKinds};

            const BindingT = struct {
                const MutableProxy = struct {
                    const Self = @This();
                    const Offset = u64;

                    pub const Error = BlobT.Error || CacheT.Error;

                    blob: *BlobT,
                    cache: *CacheT,
                    transaction_generation: ?u64,

                    fn requireTransaction(self: *const Self) Self.Error!void {
                        if (self.transaction_generation == null or
                            self.cache.transactionGeneration() != self.transaction_generation)
                        {
                            return Self.Error.TransactionInactive;
                        }
                    }

                    pub fn size(self: *const Self) Self.Error!Offset {
                        return self.blob.size();
                    }

                    pub fn readAt(self: *const Self, offset: Offset, out: []u8) Self.Error!usize {
                        const position = std.math.cast(usize, offset) orelse return Self.Error.OutOfBounds;
                        return self.blob.readAt(position, out);
                    }

                    pub fn writeAt(self: *const Self, offset: Offset, bytes: []const u8) Self.Error!void {
                        try self.requireTransaction();
                        const position = std.math.cast(usize, offset) orelse return Self.Error.OutOfBounds;
                        _ = self.blob.writeAt(position, bytes) catch |err| {
                            self.cache.markTransactionFailed();
                            return err;
                        };
                    }

                    pub fn append(self: *const Self, bytes: []const u8) Self.Error!void {
                        try self.requireTransaction();
                        _ = self.blob.append(bytes) catch |err| {
                            self.cache.markTransactionFailed();
                            return err;
                        };
                    }

                    pub fn truncate(self: *const Self, new_size: Offset) Self.Error!void {
                        try self.requireTransaction();
                        const new_size_usize = std.math.cast(usize, new_size) orelse return Self.Error.OutOfBounds;
                        self.blob.truncate(new_size_usize) catch |err| {
                            self.cache.markTransactionFailed();
                            return err;
                        };
                    }

                    pub fn clear(self: *const Self) Self.Error!void {
                        try self.requireTransaction();
                        self.blob.clear() catch |err| {
                            self.cache.markTransactionFailed();
                            return err;
                        };
                    }
                };

                const ReadProxy = struct {
                    const Self = @This();
                    const Offset = u64;
                    pub const Error = BlobT.Error;

                    blob: *BlobT,

                    pub fn size(self: *const Self) @This().Error!u64 {
                        return self.blob.size();
                    }

                    pub fn readAt(self: *const Self, offset: Offset, out: []u8) @This().Error!usize {
                        const position = std.math.cast(usize, offset) orelse return @This().Error.OutOfBounds;
                        return self.blob.readAt(position, out);
                    }
                };

                pub const Manager = ManagerT;
                pub const State = StateT;
                pub const value_capacity: ?usize = null;
                pub const Blob = BlobT;
                pub const Proxy = MutableProxy;
                pub const ConstProxy = ReadProxy;
                pub const InitOptions = struct {};
                pub const TransactionState = StateT;
                pub const Error = BindingError;

                pub const Runtime = struct {
                    page_kinds: component.PageKindRange,
                    cache: *CacheT,
                    state: StateT,
                    manager: ManagerT,
                    blob: BlobT,
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
                        if (storage.first.isMax() != storage.last.isMax()) {
                            return @This().Error.BadMetadata;
                        }
                        if (storage.first.isMax()) {
                            if (storage.total_size.get() != 0) {
                                return @This().Error.BadMetadata;
                            }
                            return;
                        }
                        const first_index = std.math.cast(usize, storage.first.get()) orelse return @This().Error.BadMetadata;
                        const last_index = std.math.cast(usize, storage.last.get()) orelse return @This().Error.BadMetadata;
                        if (first_index >= page_count or last_index >= page_count) {
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
                        @compileError("fullaz-db ChainStore GC collector PageId must match CacheType.Pid");
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
                            if (!runtime.state.first.isMax()) {
                                try roots.append(allocator, runtime.state.first.get());
                            }
                        }

                        pub fn registerScanners(
                            runtime: *const Runtime,
                            collector: *CollectorT,
                        ) RegisterError!void {
                            const chunk_page_kind = runtime.page_kinds.kindAt(0) orelse unreachable;
                            try collector.registerForCycle(
                                chunk_page_kind,
                                chunk_scanner_version,
                                &runtime.blob,
                                gc.scanners.method(CollectorT, BlobT, BlobT.scanChunkRefs),
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
                        return BindingError.InvalidPageKinds;
                    }
                    const chunk_page_kind = page_kinds.kindAt(0) orelse return BindingError.InvalidPageKinds;
                    runtime.page_kinds = page_kinds;
                    runtime.cache = backend.cache();
                    runtime.state = .{};
                    runtime.manager = ManagerT.init(backend, &runtime.state);
                    runtime.blob = BlobT.init(
                        runtime.cache,
                        &runtime.manager,
                        .{ .chunk_page_kind = chunk_page_kind },
                    );
                    runtime.const_proxy = .{
                        .blob = &runtime.blob,
                    };
                }

                pub fn deinitRuntime(runtime: *Runtime) void {
                    runtime.blob.deinit();
                    runtime.* = undefined;
                }

                pub fn requireTransactionIdle(_: *const Runtime) BindingError!void {}

                pub fn reclaimPersistent(runtime: *Runtime) BindingError!void {
                    try runtime.blob.clear();
                }

                pub fn captureTransactionState(runtime: *const Runtime) TransactionState {
                    return runtime.state;
                }

                pub fn restoreTransactionState(runtime: *Runtime, state: TransactionState) void {
                    runtime.state = state;
                }

                pub fn proxy(runtime: *Runtime) Proxy {
                    return .{
                        .blob = &runtime.blob,
                        .cache = runtime.cache,
                        .transaction_generation = runtime.cache.transactionGeneration(),
                    };
                }

                pub fn proxyConst(runtime: *const Runtime) *const ConstProxy {
                    return &runtime.const_proxy;
                }

                pub fn StorageBinding(comptime StorageManagerT: type) type {
                    if (!@hasDecl(StorageManagerT, "Size")) {
                        @compileError("fullaz-db ChainStore storage manager must declare Size");
                    }
                    if (@TypeOf(StorageManagerT.Size) != type) {
                        @compileError("fullaz-db ChainStore storage manager Size must be u64");
                    }
                    if (StorageManagerT.Size != u64) {
                        @compileError("fullaz-db ChainStore storage manager Size must be u64");
                    }

                    const StorageBlobT = low_level_chain_store.Blob(
                        CacheT,
                        StorageManagerT,
                        .little,
                    );
                    const StorageInitOptionsT = struct {};
                    const StorageError = StorageBlobT.Error || error{InvalidPageKinds};

                    const StorageProxyT = struct {
                        const Self = @This();

                        pub const Error = StorageBlobT.Error || CacheT.Error;

                        blob: *StorageBlobT,
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
                            return self.blob.size();
                        }

                        pub fn readAt(self: *const Self, offset: u64, out: []u8) Self.Error!usize {
                            const position = std.math.cast(usize, offset) orelse return Self.Error.OutOfBounds;
                            return self.blob.readAt(position, out);
                        }

                        pub fn writeAt(self: *const Self, offset: u64, bytes: []const u8) Self.Error!void {
                            try self.requireTransaction();
                            const position = std.math.cast(usize, offset) orelse return Self.Error.OutOfBounds;
                            _ = self.blob.writeAt(position, bytes) catch |err| {
                                self.cache.markTransactionFailed();
                                return err;
                            };
                        }

                        pub fn append(self: *const Self, bytes: []const u8) Self.Error!void {
                            try self.requireTransaction();
                            _ = self.blob.append(bytes) catch |err| {
                                self.cache.markTransactionFailed();
                                return err;
                            };
                        }

                        pub fn truncate(self: *const Self, new_size: u64) Self.Error!void {
                            try self.requireTransaction();
                            const new_size_usize = std.math.cast(usize, new_size) orelse return Self.Error.OutOfBounds;
                            self.blob.truncate(new_size_usize) catch |err| {
                                self.cache.markTransactionFailed();
                                return err;
                            };
                        }

                        pub fn clear(self: *const Self) Self.Error!void {
                            try self.requireTransaction();
                            self.blob.clear() catch |err| {
                                self.cache.markTransactionFailed();
                                return err;
                            };
                        }
                    };

                    const StorageConstProxyT = struct {
                        const Self = @This();

                        pub const Error = StorageBlobT.Error;

                        blob: *StorageBlobT,

                        pub fn size(self: *const Self) Self.Error!u64 {
                            return self.blob.size();
                        }

                        pub fn readAt(self: *const Self, offset: u64, out: []u8) Self.Error!usize {
                            const position = std.math.cast(usize, offset) orelse return Self.Error.OutOfBounds;
                            return self.blob.readAt(position, out);
                        }
                    };

                    const StorageRuntimeT = struct {
                        page_kinds: component.PageKindRange,
                        cache: *CacheT,
                        manager: *StorageManagerT,
                        blob: StorageBlobT,
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
                            const chunk_page_kind = page_kinds.kindAt(0) orelse return error.InvalidPageKinds;

                            runtime.page_kinds = page_kinds;
                            runtime.cache = backend.cache();
                            runtime.manager = manager;
                            runtime.blob = StorageBlobT.init(
                                runtime.cache,
                                manager,
                                .{ .chunk_page_kind = chunk_page_kind },
                            );
                            runtime.const_proxy = .{ .blob = &runtime.blob };
                        }

                        pub fn deinitRuntime(runtime: *StorageRuntimeT) void {
                            runtime.blob.deinit();
                            runtime.* = undefined;
                        }

                        pub fn requireTransactionIdle(_: *const StorageRuntimeT) StorageError!void {}

                        pub fn proxy(runtime: *StorageRuntimeT) StorageProxyT {
                            return .{
                                .blob = &runtime.blob,
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
