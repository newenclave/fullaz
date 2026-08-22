const std = @import("std");
const PackedInt = @import("../../core/packed_int.zig").PackedInt;
const component = @import("../component.zig");
const FingerprintWriter = @import("../schema_fingerprint.zig").Writer;
const ChainStoreManager = @import("chain_store_manager.zig").ChainStoreManager;
const low_level_chain_store = @import("../../storage/chain_store/chain_store.zig");

pub fn chainStore(comptime options: anytype) component.Descriptor {
    const OptionsT = @TypeOf(options);
    const info = @typeInfo(OptionsT);
    if (info != .@"struct" or info.@"struct".fields.len != 0) {
        @compileError("pages.chainStore options must be an empty struct");
    }

    const Trait = struct {
        pub const kind_name: []const u8 = "fullaz.chain-store.paged";
        pub const format_version: u32 = 1;
        pub const page_kind_count: usize = 1;
        pub const page_roles: [page_kind_count][]const u8 = .{"chunk"};

        pub fn fingerprint(_: *FingerprintWriter) void {}

        pub fn Binding(comptime BackendT: type) type {
            const CacheT = BackendT.CacheType;
            const ManagerT = ChainStoreManager(BackendT);
            const BlobT = low_level_chain_store.Blob(
                CacheT,
                ManagerT,
                .little,
            );
            const BindingError = BlobT.Error || error{InvalidPageKinds};

            return struct {
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
                pub const Blob = BlobT;
                pub const Proxy = MutableProxy;
                pub const ConstProxy = ReadProxy;
                pub const InitOptions = struct {};
                pub const TransactionState = ManagerT.State;
                pub const Error = BindingError;

                pub const Runtime = struct {
                    cache: *CacheT,
                    manager: ManagerT,
                    blob: BlobT,
                    const_proxy: ConstProxy,
                };

                pub const StaticMetadata = struct {
                    const Offset = u64;
                    const PackedPageId = PackedInt(CacheT.Pid, .little);
                    const PackedSize = PackedInt(Offset, .little);

                    pub const Storage = extern struct {
                        first: PackedPageId,
                        last: PackedPageId,
                        total_size: PackedSize,
                    };

                    pub const Error = error{BadMetadata};

                    pub fn capture(runtime: *const Runtime) Storage {
                        const state = runtime.manager.getState();
                        return .{
                            .first = PackedPageId.init(state.first orelse 0),
                            .last = PackedPageId.init(state.last orelse 0),
                            .total_size = PackedSize.init(state.total_size),
                        };
                    }

                    pub fn restore(runtime: *Runtime, storage: *const Storage) void {
                        const first = storage.first.get();
                        const last = storage.last.get();
                        runtime.manager.restoreState(.{
                            .first = if (first == 0) null else first,
                            .last = if (last == 0) null else last,
                            .total_size = storage.total_size.get(),
                        });
                    }

                    pub fn validate(storage: *const Storage, page_count: usize) @This().Error!void {
                        const first = storage.first.get();
                        const last = storage.last.get();
                        if ((first == 0) != (last == 0)) {
                            return @This().Error.BadMetadata;
                        }
                        if (first == 0) {
                            if (storage.total_size.get() != 0) {
                                return @This().Error.BadMetadata;
                            }
                            return;
                        }
                        const first_index = std.math.cast(usize, first) orelse return @This().Error.BadMetadata;
                        const last_index = std.math.cast(usize, last) orelse return @This().Error.BadMetadata;
                        if (first_index >= page_count or last_index >= page_count) {
                            return @This().Error.BadMetadata;
                        }
                    }
                };

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
                    runtime.cache = backend.cache();
                    runtime.manager = ManagerT.init(backend);
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

                pub fn captureTransactionState(runtime: *const Runtime) TransactionState {
                    return runtime.manager.getState();
                }

                pub fn restoreTransactionState(runtime: *Runtime, state: TransactionState) void {
                    runtime.manager.restoreState(state);
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
            };
        }
    };
    return component.descriptor(Trait);
}
