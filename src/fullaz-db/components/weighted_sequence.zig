const std = @import("std");
const PackedInt = @import("fullaz").core.packed_int.PackedInt;
const component = @import("../component.zig");
const FingerprintWriter = @import("../schema_fingerprint.zig").Writer;
const SingleRootManager = @import("single_root_manager.zig").SingleRootManager;
const weighted_bpt = @import("fullaz").weighted_bpt;
const weighted_seq = @import("fullaz").storage.weighted_seq;

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
    const maximum_chunk_size =
        if (@hasField(OptionsT, "maximum_chunk_size")) options.maximum_chunk_size else 256;

    const ChunkSizeT = @TypeOf(maximum_chunk_size);

    switch (@typeInfo(ChunkSizeT)) {
        .int, .comptime_int => {},
        else => @compileError("fullaz-db.weightedSequence maximum_chunk_size must be an unsigned integer"),
    }
    const chunk_size = std.math.cast(usize, maximum_chunk_size) orelse
        @compileError("fullaz-db.weightedSequence maximum_chunk_size must fit usize");
    if (chunk_size == 0) {
        @compileError("fullaz-db.weightedSequence maximum_chunk_size must be non-zero");
    }

    const Trait = struct {
        pub const kind_name: []const u8 = "fullaz.weighted-sequence.paged";
        pub const format_version: u32 = 1;
        pub const page_kind_count: usize = 2;
        pub const page_roles: [page_kind_count][]const u8 = .{ "leaf", "inode" };

        pub fn fingerprint(writer: *FingerprintWriter) void {
            writer.writeInt(usize, chunk_size);
        }

        pub fn Binding(comptime BackendT: type) type {
            const CacheT = BackendT.CacheType;
            const ManagerT = SingleRootManager(BackendT);
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
                pub const Proxy = ProxyT;
                pub const ConstProxy = ConstProxyT;
                pub const InitOptions = struct {};
                pub const TransactionState = ?ManagerT.PageId;
                pub const Error = BindingError;

                pub const Runtime = struct {
                    manager: ManagerT,
                    model: ModelT,
                    tree: TreeT,
                    sequence: SequenceT,
                    const_proxy: ConstProxy,
                };

                pub const StaticMetadata = struct {
                    const PackedPageId = PackedInt(CacheT.Pid, .little);
                    pub const Storage = extern struct { root: PackedPageId };
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
                        if (root != 0 and (std.math.cast(usize, root) orelse return error.BadMetadata) >= page_count) {
                            return error.BadMetadata;
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
                        return error.InvalidPageKinds;
                    }
                    const leaf_kind = page_kinds.kindAt(0) orelse return error.InvalidPageKinds;
                    const inode_kind = page_kinds.kindAt(1) orelse return error.InvalidPageKinds;
                    runtime.manager = ManagerT.init(backend);
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

                pub fn captureTransactionState(runtime: *const Runtime) TransactionState {
                    return runtime.manager.getRoot();
                }

                pub fn restoreTransactionState(runtime: *Runtime, state: TransactionState) void {
                    runtime.manager.restoreRoot(state);
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
            };
            comptime component.assertBinding(BindingT, BackendT);
            return BindingT;
        }
    };
    return component.descriptor(Trait);
}
