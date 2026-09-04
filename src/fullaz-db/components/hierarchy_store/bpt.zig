const std = @import("std");
const fullaz = @import("fullaz");
const component = @import("../../component/component.zig");
const dynamic_metadata = @import("../../file/metadata/dynamic.zig");
const tagged = @import("../../file/tagged_fields.zig");
const hierarchy = @import("../../hierarchy.zig");
const value_envelope = @import("../../value_envelope.zig");
const embedded = @import("embedded.zig");
const PackedInt = fullaz.core.packed_int.PackedInt;
const low_level_bpt = fullaz.bpt;
const low_level_rtree = fullaz.spatial.rtree;
const weighted_bpt = fullaz.weighted_bpt;
const weighted_seq = fullaz.storage.weighted_seq;
const chain_store = fullaz.storage.chain_store;
const slot_heap_page = fullaz.page.slot_heap;
const fsm = fullaz.storage.fsm;
const low_level_slot_heap = fullaz.storage.slot_heap;
const gc = fullaz.gc;
const storage_manager = fullaz.core.storage_manager;

/// Owns a parent value editor without coupling embedded children to the parent
/// structure's concrete editor type. `finish` commits the parent value; callers
/// must use `rollback` before `deinit` on every unsuccessful path.
pub fn ParentValueLease(comptime LeaseError: type) type {
    return struct {
        const Self = @This();

        pub const Error = LeaseError;

        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        value_mut_fn: *const fn (*anyopaque) Error![]u8,
        finish_fn: *const fn (*anyopaque) Error!void,
        rollback_fn: *const fn (*anyopaque) void,
        deinit_fn: *const fn (*anyopaque, std.mem.Allocator) void,

        pub fn init(
            comptime EditorT: type,
            allocator: std.mem.Allocator,
            editor: EditorT,
        ) std.mem.Allocator.Error!Self {
            const ptr = try allocator.create(EditorT);
            ptr.* = editor;
            return .{
                .ptr = ptr,
                .allocator = allocator,
                .value_mut_fn = struct {
                    fn valueMut(ptr_: *anyopaque) Error![]u8 {
                        const typed: *EditorT = @ptrCast(@alignCast(ptr_));
                        return typed.valueMut();
                    }
                }.valueMut,
                .finish_fn = struct {
                    fn finish(ptr_: *anyopaque) Error!void {
                        const typed: *EditorT = @ptrCast(@alignCast(ptr_));
                        return typed.finish();
                    }
                }.finish,
                .rollback_fn = struct {
                    fn rollback(ptr_: *anyopaque) void {
                        const typed: *EditorT = @ptrCast(@alignCast(ptr_));
                        typed.deinit();
                    }
                }.rollback,
                .deinit_fn = struct {
                    fn deinit(ptr_: *anyopaque, allocator_: std.mem.Allocator) void {
                        const typed: *EditorT = @ptrCast(@alignCast(ptr_));
                        allocator_.destroy(typed);
                    }
                }.deinit,
            };
        }

        pub fn valueMut(self: *const Self) Error![]u8 {
            return self.value_mut_fn(self.ptr);
        }

        pub fn finish(self: *const Self) Error!void {
            return self.finish_fn(self.ptr);
        }

        pub fn rollback(self: *const Self) void {
            self.rollback_fn(self.ptr);
        }

        pub fn deinit(self: *Self) void {
            self.deinit_fn(self.ptr, self.allocator);
            self.* = undefined;
        }
    };
}

const ChildKind = enum {
    bpt,
    chain_store,
    rtree,
    weighted_sequence,
    slot_heap,
};

fn rtreeCallbackInfo(comptime CallbackT: type) std.builtin.Type.Fn {
    return switch (@typeInfo(CallbackT)) {
        .@"fn" => |info| info,
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => |info| info,
            else => @compileError("fullaz-db hierarchy R-tree callback must be a function or function pointer"),
        },
        else => @compileError("fullaz-db hierarchy R-tree callback must be a function or function pointer"),
    };
}

fn rtreeFiniteCallbackError(comptime CallbackT: type) type {
    const ReturnT = rtreeCallbackInfo(CallbackT).return_type orelse
        @compileError("fullaz-db hierarchy R-tree callback must have a return type");

    return switch (@typeInfo(ReturnT)) {
        .void => error{},
        .error_union => |error_union| blk: {
            if (error_union.payload != void) {
                @compileError("fullaz-db hierarchy R-tree callback must return void or a finite error union with void payload");
            }
            const ErrorSet = error_union.error_set;
            if (@typeInfo(ErrorSet).error_set == null) {
                @compileError("fullaz-db hierarchy R-tree callback error set cannot be anyerror");
            }
            break :blk ErrorSet;
        },
        else => @compileError("fullaz-db hierarchy R-tree callback must return void or a finite error union with void payload"),
    };
}

/// A fixed-value BPT whose values are tagged raw bytes or embedded child roots.
///
/// `parent_descriptor` and every `HierarchyT` type must be descriptors returned
/// by `bpt`. The parent must configure `fixed_value_size`; that complete value
/// is the durable inline envelope for every entry.
pub fn hierarchyCore(
    comptime HierarchyT: type,
    comptime parent_descriptor: component.Descriptor,
) component.Descriptor {
    comptime validate(HierarchyT, parent_descriptor);
    const ParentTrait = parent_descriptor.Trait;
    const hierarchy_page_kind_count = ParentTrait.page_kind_count + childPageKindCount(HierarchyT);
    const hierarchy_page_roles = comptime buildPageRoles(HierarchyT, ParentTrait.page_kind_count);

    const Trait = struct {
        pub const kind_name: []const u8 = "fullaz.bpt.embedded-hierarchy";
        pub const format_version: u32 = 3;
        pub const page_kind_count: usize = hierarchy_page_kind_count;
        pub const page_roles: [page_kind_count][]const u8 = hierarchy_page_roles;

        pub fn fingerprint(writer: *hierarchy.FingerprintWriter) void {
            writer.writeBytes(ParentTrait.kind_name);
            writer.writeInt(u32, ParentTrait.format_version);
            ParentTrait.fingerprint(writer);
            HierarchyT.writeFingerprint(writer);
        }

        pub fn Binding(comptime BackendT: type) type {
            const ParentBinding = ParentTrait.Binding(BackendT);
            const CacheT = BackendT.CacheType;
            const PageIdT = CacheT.Pid;
            const PackedRoot = PackedInt(PageIdT, .little);
            const ChildError = childErrors(HierarchyT, BackendT, 0);

            comptime {
                if (ParentTrait.fixed_value_size.? < value_envelope.envelope_byte_size +
                    maximumChildPayloadSize(HierarchyT, PageIdT))
                {
                    @compileError("fullaz-db hierarchyStore parent fixed_value_size cannot hold an embedded child envelope");
                }
                validateBptChildEnvelopeCapacities(HierarchyT, PageIdT);
            }

            const InlineRootManager = struct {
                const Self = @This();

                pub const Error = CacheT.Error;
                pub const PageId = CacheT.Pid;
                pub const StateLeaseType = struct {
                    const LeaseSelf = @This();

                    pub const Error = CacheT.Error;

                    root: *PackedRoot,

                    pub fn data(self: *const LeaseSelf) LeaseSelf.Error![]const u8 {
                        return std.mem.asBytes(self.root);
                    }

                    pub fn dataMut(self: *LeaseSelf) LeaseSelf.Error![]u8 {
                        return std.mem.asBytes(self.root);
                    }

                    pub fn finish(_: *LeaseSelf) void {}

                    pub fn deinit(_: *LeaseSelf) void {}
                };

                cache: *CacheT,
                root: *PackedRoot,

                fn init(cache: *CacheT, root: *PackedRoot) Self {
                    return .{ .cache = cache, .root = root };
                }

                pub fn state(self: *Self) Error!StateLeaseType {
                    return .{
                        .root = self.root,
                    };
                }

                pub fn destroyPage(self: *Self, page_id: PageIdT) Error!void {
                    return self.cache.free(page_id);
                }
            };

            const ChainStoreState = chain_store.State(PageIdT, u64, .little);

            const InlineChainStoreManager = struct {
                const Self = @This();

                pub const Error = CacheT.Error;
                pub const PageId = PageIdT;
                pub const Size = u64;
                pub const StateLeaseType = struct {
                    const LeaseSelf = @This();

                    pub const Error = CacheT.Error;

                    payload: *ChainStoreState,

                    pub fn data(self: *const LeaseSelf) LeaseSelf.Error![]const u8 {
                        return std.mem.asBytes(self.payload);
                    }

                    pub fn dataMut(self: *LeaseSelf) LeaseSelf.Error![]u8 {
                        return std.mem.asBytes(self.payload);
                    }

                    pub fn finish(_: *LeaseSelf) void {}

                    pub fn deinit(_: *LeaseSelf) void {}
                };

                cache: *CacheT,
                payload: *ChainStoreState,

                fn init(cache: *CacheT, payload: *ChainStoreState) Self {
                    return .{ .cache = cache, .payload = payload };
                }

                pub fn state(self: *Self) Error!StateLeaseType {
                    return .{ .payload = self.payload };
                }

                pub fn destroyPage(self: *Self, page_id: PageId) Error!void {
                    return self.cache.free(page_id);
                }
            };

            const SlotHeapChildFactory = struct {
                pub fn get(comptime index: usize) type {
                    const ChildTrait = HierarchyT.types[index].descriptor.Trait;
                    const LocationAccessor = slot_heap_page.LeafPageLocationAccessor(PageIdT, u16, .little);
                    const Payload = low_level_slot_heap.models.paged.State(
                        PageIdT,
                        u16,
                        ChildTrait.maximum_level,
                        ChildTrait.SizeClassPolicy,
                    );

                    const InlineStateManager = struct {
                        const Self = @This();

                        pub const PageId = PageIdT;
                        pub const Error = CacheT.Error;
                        pub const StateLeaseType = struct {
                            const LeaseSelf = @This();

                            pub const Error = CacheT.Error;

                            payload: *Payload,

                            pub fn data(self: *const LeaseSelf) LeaseSelf.Error![]const u8 {
                                return std.mem.asBytes(@as(*const Payload, self.payload));
                            }

                            pub fn dataMut(self: *LeaseSelf) LeaseSelf.Error![]u8 {
                                return std.mem.asBytes(self.payload);
                            }

                            pub fn finish(_: *LeaseSelf) void {}

                            pub fn deinit(_: *LeaseSelf) void {}
                        };

                        cache: *CacheT,
                        payload: *Payload,

                        pub fn init(cache: *CacheT, payload: *Payload) Self {
                            return .{ .cache = cache, .payload = payload };
                        }

                        pub fn state(self: *Self) Error!StateLeaseType {
                            return .{ .payload = self.payload };
                        }

                        pub fn destroyPage(self: *Self, page_id: PageId) Error!void {
                            return self.cache.free(page_id);
                        }
                    };
                    const HeapStateManager = storage_manager.PagedFieldStorageManager(
                        InlineStateManager,
                        Payload,
                        "heap",
                    );
                    const FsmStateManager = storage_manager.PagedFieldStorageManager(
                        InlineStateManager,
                        Payload,
                        "fsm",
                    );
                    const FsmModel = fsm.models.paged.slab.Model(
                        CacheT,
                        FsmStateManager,
                        ChildTrait.SizeClassPolicy,
                        LocationAccessor,
                    );
                    const Fsm = fsm.Fsm(FsmModel);
                    const Model = low_level_slot_heap.models.Paged(
                        CacheT,
                        HeapStateManager,
                        ChildTrait.maximum_level,
                        Fsm,
                        ChildTrait.compare,
                        ChildTrait.CompareContext,
                    );
                    const Heap = low_level_slot_heap.Heap(Model);

                    return struct {
                        pub const PayloadType = Payload;
                        pub const StateManager = InlineStateManager;
                        pub const HeapStateManagerType = HeapStateManager;
                        pub const FsmStateManagerType = FsmStateManager;
                        pub const FsmModelType = FsmModel;
                        pub const FsmType = Fsm;
                        pub const ModelType = Model;
                        pub const HeapType = Heap;

                        pub fn emptyPayload() Payload {
                            return .{};
                        }
                    };
                }
            };

            // Builds a temporary native child runtime for page scanning. The
            // neutral state is sufficient because scanners only inspect the
            // supplied page; embedded payload state is not consulted here.
            const ChildRuntimeFactory = struct {
                pub fn get(comptime index: usize) type {
                    @setEvalBranchQuota(10_000);
                    const ChildBinding = component.bindingFor(
                        HierarchyT.types[index].descriptor,
                        BackendT,
                    );
                    const StateT = ChildBinding.State;
                    const StorageManagerT = embedded.MutablePayloadStorageManager(
                        CacheT,
                        StateT,
                    );
                    const StorageBindingT = component.storageBindingFor(
                        ChildBinding,
                        BackendT,
                        StorageManagerT,
                    );

                    return struct {
                        const Self = @This();

                        pub const State = StateT;
                        pub const Error = StorageManagerT.Error || StorageBindingT.Error;

                        state: StateT,
                        manager: StorageManagerT,
                        runtime: StorageBindingT.Runtime,

                        pub fn init(
                            self: *Self,
                            backend: *BackendT,
                            page_kinds: component.PageKindRange,
                        ) Error!void {
                            self.state = StorageBindingT.emptyState();
                            self.manager = try StorageManagerT.init(
                                backend.cache(),
                                std.mem.asBytes(&self.state),
                            );
                            try StorageBindingT.initRuntime(
                                &self.runtime,
                                backend,
                                &self.manager,
                                page_kinds,
                                .{},
                            );
                        }

                        pub fn deinit(self: *Self) void {
                            StorageBindingT.deinitRuntime(&self.runtime);
                            self.* = undefined;
                        }
                    };
                }
            };

            const ConstRuntime = struct {
                parent: *const ParentBinding.Runtime,
                backend: *BackendT,
                type_page_kinds: component.PageKindRange,

                fn childPageKinds(self: *const @This(), comptime index: usize) component.PageKindRange {
                    return .{
                        .base = @intCast(@as(u32, self.type_page_kinds.base) +
                            childPageKindOffset(HierarchyT, index)),
                        .count = HierarchyT.types[index].descriptor.Trait.page_kind_count,
                    };
                }
            };

            const ConstProxyImpl = struct {
                const Self = @This();

                pub const Error = ParentBinding.ConstProxy.Error ||
                    ChildError ||
                    value_envelope.Error ||
                    std.mem.Allocator.Error ||
                    error{ReadOnly};
                pub const Iterator = ParentBinding.ConstProxy.Iterator;
                pub const ConstIterator = Iterator;

                runtime: *const ConstRuntime,

                fn ChildBindingForTag(comptime tag: []const u8) type {
                    return component.bindingFor(
                        HierarchyT.entryByTag(tag).descriptor,
                        BackendT,
                    );
                }

                fn init(runtime: *const ConstRuntime) Self {
                    return .{ .runtime = runtime };
                }

                fn parent(self: *const Self) *const ParentBinding.ConstProxy {
                    return ParentBinding.proxyConst(self.runtime.parent);
                }

                pub fn iterator(self: *const Self) ParentBinding.ConstProxy.Error!?Iterator {
                    return self.parent().iterator();
                }

                pub fn iteratorFromEnd(self: *const Self) ParentBinding.ConstProxy.Error!?Iterator {
                    return self.parent().iteratorFromEnd();
                }

                pub fn find(self: *const Self, key: []const u8) ParentBinding.ConstProxy.Error!?Iterator {
                    return self.parent().find(key);
                }

                pub fn lowerBound(self: *const Self, key: []const u8) ParentBinding.ConstProxy.Error!?Iterator {
                    return self.parent().lowerBound(key);
                }

                /// Opens an exact embedded child through its StorageBinding and
                /// retains the parent iterator until the child closes.
                pub fn openEmbedded(
                    self: *const Self,
                    key: []const u8,
                    comptime tag: []const u8,
                ) Error!?embedded.OwnedConstChild(
                    BackendT,
                    ChildBindingForTag(tag),
                    ParentBinding.ConstProxy.Iterator,
                ) {
                    var parent_iterator = (try self.find(key)) orelse return null;
                    var transferred = false;
                    errdefer if (!transferred) {
                        parent_iterator.deinit();
                    };
                    const entry = (try parent_iterator.get()) orelse return null;
                    const value = try value_envelope.readEmbedded(
                        entry.value,
                        HierarchyT.entryByTag(tag).type_identity,
                    );
                    const ChildBinding = ChildBindingForTag(tag);
                    const Child = embedded.OwnedConstChild(
                        BackendT,
                        ChildBinding,
                        ParentBinding.ConstProxy.Iterator,
                    );
                    const child = try Child.init(
                        self.runtime.backend,
                        value.payload,
                        parent_iterator,
                        self.runtime.childPageKinds(HierarchyT.indexOfTag(tag)),
                        .{},
                    );
                    transferred = true;
                    return child;
                }
            };

            const RuntimeImpl = struct {
                const RuntimeSelf = @This();
                parent: ParentBinding.Runtime,
                backend: *BackendT,
                page_kinds: component.PageKindRange,
                type_page_kinds: component.PageKindRange,
                const_runtime: ConstRuntime,
                const_proxy: ConstProxyImpl,
                active_editor: bool = false,
                next_instance_id: u64 = 1,
                aggregate_next_instance_id: ?*u64 = null,

                fn parentPageKinds(self: *const @This()) component.PageKindRange {
                    return .{ .base = self.page_kinds.base, .count = ParentTrait.page_kind_count };
                }

                fn childPageKinds(self: *const @This(), comptime index: usize) component.PageKindRange {
                    return .{
                        .base = @intCast(@as(u32, self.type_page_kinds.base) +
                            childPageKindOffset(HierarchyT, index)),
                        .count = HierarchyT.types[index].descriptor.Trait.page_kind_count,
                    };
                }

                fn nextMetadata(self: *@This(), comptime tag: []const u8) value_envelope.Metadata {
                    const next_instance_id = self.aggregate_next_instance_id orelse &self.next_instance_id;
                    const instance_id = next_instance_id.*;
                    next_instance_id.* = std.math.add(u64, instance_id, 1) catch
                        @panic("fullaz-db hierarchy instance ID space exhausted");
                    return .{
                        .registry_id = HierarchyT.registry_id,
                        .type_id = HierarchyT.entryByTag(tag).type_identity.type_id,
                        .type_version = HierarchyT.entryByTag(tag).type_identity.type_version,
                        .metadata_format_version = HierarchyT.entryByTag(tag).type_identity.metadata_format_version,
                        .instance_id = instance_id,
                        .revision = 0,
                    };
                }

                fn scanParentLeaf(
                    self: *const @This(),
                    page_id: PageIdT,
                    page: []const u8,
                    visitor: anytype,
                ) !void {
                    return self.parent.tree.scanLeafRefs(page_id, page, visitor);
                }

                fn scanBptChildLeaf(
                    self: *const @This(),
                    comptime index: usize,
                    page_id: PageIdT,
                    page: []const u8,
                    visitor: anytype,
                ) !void {
                    var child: ChildRuntimeFactory.get(index) = undefined;
                    try child.init(
                        self.backend,
                        self.childPageKinds(index),
                    );
                    defer child.deinit();
                    return child.runtime.tree.scanLeafRefs(page_id, page, visitor);
                }

                fn scanBptChildInode(
                    self: *const @This(),
                    comptime index: usize,
                    page_id: PageIdT,
                    page: []const u8,
                    visitor: anytype,
                ) !void {
                    var child: ChildRuntimeFactory.get(index) = undefined;
                    try child.init(
                        self.backend,
                        self.childPageKinds(index),
                    );
                    defer child.deinit();
                    return child.runtime.tree.scanInodeRefs(page_id, page, visitor);
                }

                fn scanWeightedSequenceChildLeaf(
                    self: *const @This(),
                    comptime index: usize,
                    page_id: PageIdT,
                    page: []const u8,
                    visitor: anytype,
                ) !void {
                    var child: ChildRuntimeFactory.get(index) = undefined;
                    try child.init(
                        self.backend,
                        self.childPageKinds(index),
                    );
                    defer child.deinit();
                    return child.runtime.sequence.scanLeafRefs(page_id, page, visitor);
                }

                fn scanWeightedSequenceChildInode(
                    self: *const @This(),
                    comptime index: usize,
                    page_id: PageIdT,
                    page: []const u8,
                    visitor: anytype,
                ) !void {
                    var child: ChildRuntimeFactory.get(index) = undefined;
                    try child.init(
                        self.backend,
                        self.childPageKinds(index),
                    );
                    defer child.deinit();
                    return child.runtime.sequence.scanInodeRefs(page_id, page, visitor);
                }

                fn scanChainStoreChild(
                    self: *const @This(),
                    comptime index: usize,
                    page_id: PageIdT,
                    page: []const u8,
                    visitor: anytype,
                ) !void {
                    var child: ChildRuntimeFactory.get(index) = undefined;
                    try child.init(
                        self.backend,
                        self.childPageKinds(index),
                    );
                    defer child.deinit();
                    return child.runtime.blob.scanChunkRefs(page_id, page, visitor);
                }

                fn scanRtreeChildLeaf(
                    self: *const @This(),
                    comptime index: usize,
                    page_id: PageIdT,
                    page: []const u8,
                    visitor: anytype,
                ) !void {
                    var child: ChildRuntimeFactory.get(index) = undefined;
                    try child.init(
                        self.backend,
                        self.childPageKinds(index),
                    );
                    defer child.deinit();
                    return child.runtime.tree.scanLeafRefs(page_id, page, visitor);
                }

                fn scanRtreeChildInode(
                    self: *const @This(),
                    comptime index: usize,
                    page_id: PageIdT,
                    page: []const u8,
                    visitor: anytype,
                ) !void {
                    var child: ChildRuntimeFactory.get(index) = undefined;
                    try child.init(
                        self.backend,
                        self.childPageKinds(index),
                    );
                    defer child.deinit();
                    return child.runtime.tree.scanInodeRefs(page_id, page, visitor);
                }

                fn scanSlotHeapChildLeaf(
                    self: *const @This(),
                    comptime index: usize,
                    page_id: PageIdT,
                    page: []const u8,
                    visitor: anytype,
                ) !void {
                    var child: ChildRuntimeFactory.get(index) = undefined;
                    try child.init(
                        self.backend,
                        self.childPageKinds(index),
                    );
                    defer child.deinit();
                    return child.runtime.heap.scanLeafRefs(page_id, page, visitor);
                }

                fn scanSlotHeapChildInode(
                    self: *const @This(),
                    comptime index: usize,
                    page_id: PageIdT,
                    page: []const u8,
                    visitor: anytype,
                ) !void {
                    var child: ChildRuntimeFactory.get(index) = undefined;
                    try child.init(
                        self.backend,
                        self.childPageKinds(index),
                    );
                    defer child.deinit();
                    return child.runtime.heap.scanInodeRefs(page_id, page, visitor);
                }

                fn scanSlotHeapChildFsmSlab(
                    self: *const @This(),
                    comptime index: usize,
                    page_id: PageIdT,
                    page: []const u8,
                    visitor: anytype,
                ) !void {
                    var child: ChildRuntimeFactory.get(index) = undefined;
                    try child.init(
                        self.backend,
                        self.childPageKinds(index),
                    );
                    defer child.deinit();
                    return child.runtime.fsm.scanSlabRefs(page_id, page, visitor);
                }

                fn valueScanner(comptime CollectorT: type) CollectorT.ValueScanner {
                    return struct {
                        fn scan(
                            context: ?*const anyopaque,
                            bytes: []const u8,
                            sink: CollectorT.ReferenceSink,
                        ) CollectorT.Error!void {
                            _ = @as(
                                *const RuntimeSelf,
                                @ptrCast(@alignCast(context orelse return error.InvalidScannerContext)),
                            );
                            // R-tree and SlotHeap descendants retain support for native
                            // values. Only values carrying the envelope magic participate
                            // in hierarchy root discovery; malformed envelopes are invalid.
                            if (bytes.len < value_envelope.magic.len or
                                !std.mem.eql(u8, bytes[0..value_envelope.magic.len], value_envelope.magic))
                            {
                                return;
                            }
                            const value = value_envelope.readAny(bytes) catch return error.InvalidPage;
                            if (value.kind == .raw) {
                                return;
                            }
                            inline for (HierarchyT.types, 0..) |entry, index| {
                                const identity = entry.type_identity;
                                if (value.metadata.registry_id == identity.registry_id and
                                    value.metadata.type_id == identity.type_id and
                                    value.metadata.type_version == identity.type_version and
                                    value.metadata.metadata_format_version == identity.metadata_format_version)
                                {
                                    const Child = ChildRuntimeFactory.get(index);
                                    if (value.payload.len != @sizeOf(Child.State)) {
                                        return error.InvalidPage;
                                    }
                                    const state: *const Child.State = @ptrCast(value.payload.ptr);
                                    if (comptime childKind(HierarchyT, index) == .slot_heap) {
                                        if (!state.heap.root.isMax()) {
                                            try sink.visit(state.heap.root.get());
                                        }
                                        for (state.fsm.classes) |class_state| {
                                            if (!class_state.first.isMax()) {
                                                try sink.visit(class_state.first.get());
                                            }
                                        }
                                    } else if (comptime childKind(HierarchyT, index) == .chain_store) {
                                        if (!state.first.isMax()) {
                                            try sink.visit(state.first.get());
                                        }
                                    } else {
                                        if (!state.root.isMax()) {
                                            try sink.visit(state.root.get());
                                        }
                                    }
                                    return;
                                }
                            }
                            return error.InvalidPage;
                        }
                    }.scan;
                }

                fn bptChildLeafScanner(comptime CollectorT: type, comptime index: usize) CollectorT.Scanner {
                    return struct {
                        fn scan(
                            context: ?*const anyopaque,
                            page_id: CollectorT.PageId,
                            page: []const u8,
                            sink: CollectorT.ReferenceSink,
                        ) CollectorT.Error!void {
                            const runtime: *const RuntimeSelf = @ptrCast(@alignCast(context orelse return error.InvalidScannerContext));
                            var visitor = SinkVisitor(CollectorT){ .sink = sink };
                            runtime.scanBptChildLeaf(index, page_id, page, &visitor) catch |err| {
                                if (err == error.Abort) {
                                    return visitor.sink_error.?;
                                }
                                return error.InvalidPage;
                            };
                        }
                    }.scan;
                }

                fn bptChildInodeScanner(comptime CollectorT: type, comptime index: usize) CollectorT.Scanner {
                    return struct {
                        fn scan(
                            context: ?*const anyopaque,
                            page_id: CollectorT.PageId,
                            page: []const u8,
                            sink: CollectorT.ReferenceSink,
                        ) CollectorT.Error!void {
                            const runtime: *const RuntimeSelf = @ptrCast(@alignCast(context orelse return error.InvalidScannerContext));
                            var visitor = SinkVisitor(CollectorT){ .sink = sink };
                            runtime.scanBptChildInode(index, page_id, page, &visitor) catch |err| {
                                if (err == error.Abort) {
                                    return visitor.sink_error.?;
                                }
                                return error.InvalidPage;
                            };
                        }
                    }.scan;
                }

                fn weightedSequenceChildLeafScanner(comptime CollectorT: type, comptime index: usize) CollectorT.Scanner {
                    return struct {
                        fn scan(
                            context: ?*const anyopaque,
                            page_id: CollectorT.PageId,
                            page: []const u8,
                            sink: CollectorT.ReferenceSink,
                        ) CollectorT.Error!void {
                            const runtime: *const RuntimeSelf = @ptrCast(@alignCast(context orelse return error.InvalidScannerContext));
                            var visitor = SinkVisitor(CollectorT){ .sink = sink };
                            runtime.scanWeightedSequenceChildLeaf(index, page_id, page, &visitor) catch |err| {
                                if (err == error.Abort) {
                                    return visitor.sink_error.?;
                                }
                                return error.InvalidPage;
                            };
                        }
                    }.scan;
                }

                fn weightedSequenceChildInodeScanner(comptime CollectorT: type, comptime index: usize) CollectorT.Scanner {
                    return struct {
                        fn scan(
                            context: ?*const anyopaque,
                            page_id: CollectorT.PageId,
                            page: []const u8,
                            sink: CollectorT.ReferenceSink,
                        ) CollectorT.Error!void {
                            const runtime: *const RuntimeSelf = @ptrCast(@alignCast(context orelse return error.InvalidScannerContext));
                            var visitor = SinkVisitor(CollectorT){ .sink = sink };
                            runtime.scanWeightedSequenceChildInode(index, page_id, page, &visitor) catch |err| {
                                if (err == error.Abort) {
                                    return visitor.sink_error.?;
                                }
                                return error.InvalidPage;
                            };
                        }
                    }.scan;
                }

                fn chainStoreChildScanner(comptime CollectorT: type, comptime index: usize) CollectorT.Scanner {
                    return struct {
                        fn scan(
                            context: ?*const anyopaque,
                            page_id: CollectorT.PageId,
                            page: []const u8,
                            sink: CollectorT.ReferenceSink,
                        ) CollectorT.Error!void {
                            const runtime: *const RuntimeSelf = @ptrCast(@alignCast(context orelse return error.InvalidScannerContext));
                            var visitor = SinkVisitor(CollectorT){ .sink = sink };
                            runtime.scanChainStoreChild(index, page_id, page, &visitor) catch |err| {
                                if (err == error.Abort) {
                                    return visitor.sink_error.?;
                                }
                                return error.InvalidPage;
                            };
                        }
                    }.scan;
                }

                fn rtreeChildLeafScanner(comptime CollectorT: type, comptime index: usize) CollectorT.Scanner {
                    return struct {
                        fn scan(
                            context: ?*const anyopaque,
                            page_id: CollectorT.PageId,
                            page: []const u8,
                            sink: CollectorT.ReferenceSink,
                        ) CollectorT.Error!void {
                            const runtime: *const RuntimeSelf = @ptrCast(@alignCast(context orelse return error.InvalidScannerContext));
                            var visitor = SinkVisitor(CollectorT){ .sink = sink };
                            runtime.scanRtreeChildLeaf(index, page_id, page, &visitor) catch |err| {
                                if (err == error.Abort) {
                                    return visitor.sink_error.?;
                                }
                                return error.InvalidPage;
                            };
                        }
                    }.scan;
                }

                fn rtreeChildInodeScanner(comptime CollectorT: type, comptime index: usize) CollectorT.Scanner {
                    return struct {
                        fn scan(
                            context: ?*const anyopaque,
                            page_id: CollectorT.PageId,
                            page: []const u8,
                            sink: CollectorT.ReferenceSink,
                        ) CollectorT.Error!void {
                            const runtime: *const RuntimeSelf = @ptrCast(@alignCast(context orelse return error.InvalidScannerContext));
                            var visitor = SinkVisitor(CollectorT){ .sink = sink };
                            runtime.scanRtreeChildInode(index, page_id, page, &visitor) catch |err| {
                                if (err == error.Abort) {
                                    return visitor.sink_error.?;
                                }
                                return error.InvalidPage;
                            };
                        }
                    }.scan;
                }

                fn slotHeapChildLeafScanner(comptime CollectorT: type, comptime index: usize) CollectorT.Scanner {
                    return struct {
                        fn scan(
                            context: ?*const anyopaque,
                            page_id: CollectorT.PageId,
                            page: []const u8,
                            sink: CollectorT.ReferenceSink,
                        ) CollectorT.Error!void {
                            const runtime: *const RuntimeSelf = @ptrCast(@alignCast(context orelse return error.InvalidScannerContext));
                            var visitor = SinkVisitor(CollectorT){ .sink = sink };
                            runtime.scanSlotHeapChildLeaf(index, page_id, page, &visitor) catch |err| {
                                if (err == error.Abort) {
                                    return visitor.sink_error.?;
                                }
                                return error.InvalidPage;
                            };
                        }
                    }.scan;
                }

                fn slotHeapChildInodeScanner(comptime CollectorT: type, comptime index: usize) CollectorT.Scanner {
                    return struct {
                        fn scan(
                            context: ?*const anyopaque,
                            page_id: CollectorT.PageId,
                            page: []const u8,
                            sink: CollectorT.ReferenceSink,
                        ) CollectorT.Error!void {
                            const runtime: *const RuntimeSelf = @ptrCast(@alignCast(context orelse return error.InvalidScannerContext));
                            var visitor = SinkVisitor(CollectorT){ .sink = sink };
                            runtime.scanSlotHeapChildInode(index, page_id, page, &visitor) catch |err| {
                                if (err == error.Abort) {
                                    return visitor.sink_error.?;
                                }
                                return error.InvalidPage;
                            };
                        }
                    }.scan;
                }

                fn slotHeapChildFsmSlabScanner(comptime CollectorT: type, comptime index: usize) CollectorT.Scanner {
                    return struct {
                        fn scan(
                            context: ?*const anyopaque,
                            page_id: CollectorT.PageId,
                            page: []const u8,
                            sink: CollectorT.ReferenceSink,
                        ) CollectorT.Error!void {
                            const runtime: *const RuntimeSelf = @ptrCast(@alignCast(context orelse return error.InvalidScannerContext));
                            var visitor = SinkVisitor(CollectorT){ .sink = sink };
                            runtime.scanSlotHeapChildFsmSlab(index, page_id, page, &visitor) catch |err| {
                                if (err == error.Abort) {
                                    return visitor.sink_error.?;
                                }
                                return error.InvalidPage;
                            };
                        }
                    }.scan;
                }
            };

            const EmbeddedValue = struct { metadata: value_envelope.Metadata };
            const Value = union(enum) {
                raw: struct { metadata: value_envelope.Metadata, payload: []const u8 },
                embedded: EmbeddedValue,
            };

            const ValueEditorOwner = ParentValueLease(ParentBinding.Error || ChildError);

            const BptEditorState = struct {
                child_active: bool = false,
            };

            const editor_lease = struct {
                fn release(runtime: *RuntimeImpl, parent_state: ?*BptEditorState) void {
                    if (parent_state) |state| {
                        state.child_active = false;
                    } else {
                        runtime.active_editor = false;
                    }
                }

                fn activate(runtime: *RuntimeImpl, parent_state: ?*BptEditorState) void {
                    if (parent_state) |state| {
                        state.child_active = true;
                    } else {
                        runtime.active_editor = true;
                    }
                }
            };

            const EditorTypes = struct {
                const BptEditorFactory = struct {
                    pub fn get(comptime tag: []const u8) type {
                        const ChildTrait = HierarchyT.entryByTag(tag).descriptor.Trait;
                        const ChildModel = low_level_bpt.models.PagedModel(
                            CacheT,
                            InlineRootManager,
                            ChildTrait.compare,
                            ChildTrait.CompareContext,
                        );
                        const ChildTree = low_level_bpt.Bpt(ChildModel);

                        return struct {
                            const Self = @This();

                            parent_editor: ValueEditorOwner,
                            envelope_editor: value_envelope.EmbeddedEditor,
                            manager: *InlineRootManager,
                            model: *ChildModel,
                            tree: ChildTree,
                            runtime: *RuntimeImpl,
                            transaction_generation: ?u64,
                            parent_state: ?*BptEditorState,
                            state: *BptEditorState,
                            closed: bool = false,

                            fn requireOpen(self: *const Self) (ChildTree.Error || value_envelope.Error)!void {
                                if (self.closed or !self.runtime.active_editor) {
                                    return error.EditorInvalidated;
                                }
                                if (self.transaction_generation == null or
                                    self.runtime.backend.cache().transactionGeneration() != self.transaction_generation)
                                {
                                    return error.TransactionInactive;
                                }
                            }

                            fn requireMutable(self: *const Self) (ChildTree.Error || value_envelope.Error || error{EditorActive})!void {
                                try self.requireOpen();
                                if (self.state.child_active) {
                                    return error.EditorActive;
                                }
                            }

                            pub fn raw(self: *Self, comptime value_tag: []const u8, payload: []const u8) Value {
                                return .{ .raw = .{
                                    .metadata = self.runtime.nextMetadata(value_tag),
                                    .payload = payload,
                                } };
                            }

                            pub fn embed(
                                self: *Self,
                                comptime child_tag: []const u8,
                            ) error{ChildTypeNotAllowed}!Value {
                                const parent_type_id = HierarchyT.entryByTag(tag).type_identity.type_id;
                                const child_type_id = HierarchyT.entryByTag(child_tag).type_identity.type_id;
                                if (comptime !HierarchyT.allowsChild(parent_type_id, child_type_id)) {
                                    return error.ChildTypeNotAllowed;
                                }
                                return .{ .embedded = .{
                                    .metadata = self.runtime.nextMetadata(child_tag),
                                } };
                            }

                            pub fn insert(self: *Self, key: []const u8, value: Value) (ChildTree.Error || value_envelope.Error || error{EditorActive})!bool {
                                try self.requireMutable();
                                var bytes: [ChildTrait.fixed_value_size.?]u8 = undefined;
                                try format_hierarchy_value(&bytes, value);
                                return self.tree.insert(key, &bytes) catch |err| {
                                    self.runtime.backend.cache().markTransactionFailed();
                                    return err;
                                };
                            }

                            pub fn update(self: *Self, key: []const u8, value: Value) (ChildTree.Error || value_envelope.Error || error{EditorActive})!bool {
                                try self.requireMutable();
                                var bytes: [ChildTrait.fixed_value_size.?]u8 = undefined;
                                try format_hierarchy_value(&bytes, value);
                                return self.tree.update(key, &bytes) catch |err| {
                                    self.runtime.backend.cache().markTransactionFailed();
                                    return err;
                                };
                            }

                            pub fn remove(self: *Self, key: []const u8) (ChildTree.Error || value_envelope.Error || error{EditorActive})!bool {
                                try self.requireMutable();
                                return self.tree.remove(key) catch |err| {
                                    self.runtime.backend.cache().markTransactionFailed();
                                    return err;
                                };
                            }

                            pub fn find(self: *Self, key: []const u8) (ChildTree.Error || value_envelope.Error)!?ChildTree.Iterator {
                                try self.requireOpen();
                                return self.tree.find(key);
                            }

                            pub fn openEmbeddedForEdit(
                                self: *Self,
                                key: []const u8,
                                comptime child_tag: []const u8,
                            ) (ChildTree.Error || ChildError || value_envelope.Error || error{EditorActive})!?EditorForTag(child_tag) {
                                try self.requireMutable();
                                var parent_editor = (try self.tree.openValueEditor(key)) orelse return null;
                                var parent_editor_transferred = false;
                                errdefer if (!parent_editor_transferred) {
                                    parent_editor.deinit();
                                };
                                var envelope_editor = try value_envelope.openEmbeddedMut(
                                    try parent_editor.valueMut(),
                                    HierarchyT.entryByTag(child_tag).type_identity,
                                );
                                errdefer envelope_editor.invalidate();
                                var owner = try ValueEditorOwner.init(
                                    ChildTree.ValueEditor,
                                    self.runtime.backend.allocator(),
                                    parent_editor,
                                );
                                parent_editor_transferred = true;
                                errdefer {
                                    owner.rollback();
                                    owner.deinit();
                                }
                                const payload = try envelope_editor.payloadMut();
                                var proxy = ProxyImpl{
                                    .runtime = self.runtime,
                                    .transaction_generation = self.transaction_generation,
                                };
                                return switch (comptime childKind(HierarchyT, HierarchyT.indexOfTag(child_tag))) {
                                    .bpt => try proxy.openBptEmbeddedForEdit(
                                        owner,
                                        envelope_editor,
                                        payload,
                                        child_tag,
                                        self.state,
                                    ),
                                    .chain_store => try proxy.openChainStoreEmbeddedForEdit(
                                        owner,
                                        envelope_editor,
                                        payload,
                                        child_tag,
                                        self.state,
                                    ),
                                    .weighted_sequence => try proxy.openWeightedSequenceEmbeddedForEdit(
                                        owner,
                                        envelope_editor,
                                        payload,
                                        child_tag,
                                        self.state,
                                    ),
                                    .rtree => try proxy.openRtreeEmbeddedForEdit(
                                        owner,
                                        envelope_editor,
                                        payload,
                                        child_tag,
                                        self.state,
                                    ),
                                    .slot_heap => try proxy.openSlotHeapEmbeddedForEdit(
                                        owner,
                                        envelope_editor,
                                        payload,
                                        child_tag,
                                        self.state,
                                    ),
                                };
                            }

                            fn EditorForTag(comptime child_tag: []const u8) type {
                                return switch (childKind(HierarchyT, HierarchyT.indexOfTag(child_tag))) {
                                    .bpt => BptEditorFactory.get(child_tag),
                                    .chain_store => ChainStoreEditorFactory.get(child_tag),
                                    .weighted_sequence => WeightedSequenceEditorFactory.get(child_tag),
                                    .rtree => RtreeEditorFactory.get(child_tag),
                                    .slot_heap => SlotHeapEditorFactory.get(child_tag),
                                };
                            }

                            pub fn root(self: *const Self) ?PageIdT {
                                return if (self.manager.root.isMax())
                                    null
                                else
                                    self.manager.root.get();
                            }

                            pub fn finish(self: *Self) (ChildTree.Error || ValueEditorOwner.Error || value_envelope.Error || error{ChildEditorActive})!void {
                                try self.requireOpen();
                                if (self.state.child_active) {
                                    return error.ChildEditorActive;
                                }
                                try self.envelope_editor.advanceRevision();
                                try self.envelope_editor.finish();
                                try self.parent_editor.finish();
                                self.release();
                            }

                            pub fn deinit(self: *Self) void {
                                if (!self.closed) {
                                    if (self.state.child_active) {
                                        self.runtime.backend.cache().markTransactionFailed();
                                        return;
                                    }
                                    self.envelope_editor.invalidate();
                                    self.runtime.backend.cache().markTransactionFailed();
                                    self.release();
                                }
                            }

                            fn release(self: *Self) void {
                                self.tree.deinit();
                                self.model.deinit();
                                self.runtime.backend.allocator().destroy(self.model);
                                self.runtime.backend.allocator().destroy(self.manager);
                                self.parent_editor.rollback();
                                self.parent_editor.deinit();
                                self.runtime.backend.allocator().destroy(self.state);
                                editor_lease.release(self.runtime, self.parent_state);
                                self.closed = true;
                            }
                        };
                    }
                };

                const ChainStoreEditorFactory = struct {
                    pub fn get(comptime tag: []const u8) type {
                        _ = tag;
                        const ChainBlob = fullaz.storage.chain_store.Blob(
                            CacheT,
                            InlineChainStoreManager,
                            .little,
                        );

                        return struct {
                            const Self = @This();

                            parent_editor: ValueEditorOwner,
                            envelope_editor: value_envelope.EmbeddedEditor,
                            manager: *InlineChainStoreManager,
                            blob: ChainBlob,
                            runtime: *RuntimeImpl,
                            transaction_generation: ?u64,
                            parent_state: ?*BptEditorState,
                            closed: bool = false,

                            fn requireOpen(self: *const Self) (ChainBlob.Error || value_envelope.Error)!void {
                                if (self.closed or !self.runtime.active_editor) {
                                    return error.EditorInvalidated;
                                }
                                if (self.transaction_generation == null or
                                    self.runtime.backend.cache().transactionGeneration() != self.transaction_generation)
                                {
                                    return error.TransactionInactive;
                                }
                            }

                            pub fn size(self: *const Self) (ChainBlob.Error || value_envelope.Error)!u64 {
                                try self.requireOpen();
                                return self.blob.size();
                            }

                            pub fn readAt(
                                self: *Self,
                                offset: u64,
                                out: []u8,
                            ) (ChainBlob.Error || value_envelope.Error)!usize {
                                try self.requireOpen();
                                const position = std.math.cast(usize, offset) orelse return error.OutOfBounds;
                                return self.blob.readAt(position, out);
                            }

                            pub fn writeAt(
                                self: *Self,
                                offset: u64,
                                bytes: []const u8,
                            ) (ChainBlob.Error || value_envelope.Error)!void {
                                try self.requireOpen();
                                const position = std.math.cast(usize, offset) orelse return error.OutOfBounds;
                                _ = self.blob.writeAt(position, bytes) catch |err| {
                                    self.runtime.backend.cache().markTransactionFailed();
                                    return err;
                                };
                            }

                            pub fn append(self: *Self, bytes: []const u8) (ChainBlob.Error || value_envelope.Error)!void {
                                try self.requireOpen();
                                _ = self.blob.append(bytes) catch |err| {
                                    self.runtime.backend.cache().markTransactionFailed();
                                    return err;
                                };
                            }

                            pub fn truncate(self: *Self, new_size: u64) (ChainBlob.Error || value_envelope.Error)!void {
                                try self.requireOpen();
                                const new_size_usize = std.math.cast(usize, new_size) orelse return error.OutOfBounds;
                                self.blob.truncate(new_size_usize) catch |err| {
                                    self.runtime.backend.cache().markTransactionFailed();
                                    return err;
                                };
                            }

                            pub fn clear(self: *Self) (ChainBlob.Error || value_envelope.Error)!void {
                                try self.requireOpen();
                                self.blob.clear() catch |err| {
                                    self.runtime.backend.cache().markTransactionFailed();
                                    return err;
                                };
                            }

                            /// Returns the canonical root of the chunk chain.
                            pub fn first(self: *const Self) (ChainBlob.Error || value_envelope.Error)!?PageIdT {
                                try self.requireOpen();
                                return if (self.manager.payload.first.isMax())
                                    null
                                else
                                    self.manager.payload.first.get();
                            }

                            pub fn finish(self: *Self) (ChainBlob.Error || ValueEditorOwner.Error || value_envelope.Error)!void {
                                try self.requireOpen();
                                try self.envelope_editor.advanceRevision();
                                try self.envelope_editor.finish();
                                try self.parent_editor.finish();
                                self.release();
                            }

                            pub fn deinit(self: *Self) void {
                                if (!self.closed) {
                                    self.envelope_editor.invalidate();
                                    self.runtime.backend.cache().markTransactionFailed();
                                    self.release();
                                }
                            }

                            fn release(self: *Self) void {
                                self.blob.deinit();
                                self.runtime.backend.allocator().destroy(self.manager);
                                self.parent_editor.rollback();
                                self.parent_editor.deinit();
                                editor_lease.release(self.runtime, self.parent_state);
                                self.closed = true;
                            }
                        };
                    }
                };

                const WeightedSequenceEditorFactory = struct {
                    pub fn get(comptime tag: []const u8) type {
                        const ChildTrait = HierarchyT.entryByTag(tag).descriptor.Trait;
                        const ChildModel = weighted_bpt.models.paged.PagedModel(
                            CacheT,
                            InlineRootManager,
                            u64,
                            void,
                        );
                        const ChildTree = weighted_bpt.WeightedBpt(ChildModel);
                        const Sequence = weighted_seq.WeightedSeq(
                            ChildTree,
                            ChildTrait.maximum_chunk_size,
                        );

                        return struct {
                            const Self = @This();

                            pub const Error = Sequence.Error || ValueEditorOwner.Error || value_envelope.Error;

                            parent_editor: ValueEditorOwner,
                            envelope_editor: value_envelope.EmbeddedEditor,
                            manager: *InlineRootManager,
                            model: *ChildModel,
                            tree: ChildTree,
                            runtime: *RuntimeImpl,
                            transaction_generation: ?u64,
                            parent_state: ?*BptEditorState,
                            closed: bool = false,

                            fn requireOpen(self: *const Self) Error!void {
                                if (self.closed or !self.runtime.active_editor) {
                                    return error.EditorInvalidated;
                                }
                                if (self.transaction_generation == null or
                                    self.runtime.backend.cache().transactionGeneration() != self.transaction_generation)
                                {
                                    return error.TransactionInactive;
                                }
                            }

                            fn currentSequence(self: *Self) Sequence {
                                return Sequence.init(&self.tree);
                            }

                            pub fn size(self: *Self) Error!u64 {
                                try self.requireOpen();
                                var seq = self.currentSequence();
                                return seq.size();
                            }

                            pub fn readAt(self: *Self, offset: u64, out: []u8) Error!usize {
                                try self.requireOpen();
                                var seq = self.currentSequence();
                                return seq.readAt(offset, out);
                            }

                            pub fn insert(self: *Self, offset: u64, bytes: []const u8) Error!void {
                                try self.requireOpen();
                                var seq = self.currentSequence();
                                seq.insert(offset, bytes) catch |err| {
                                    self.runtime.backend.cache().markTransactionFailed();
                                    return err;
                                };
                            }

                            pub fn append(self: *Self, bytes: []const u8) Error!void {
                                try self.insert(try self.size(), bytes);
                            }

                            pub fn erase(self: *Self, offset: u64, len: u64) Error!void {
                                try self.requireOpen();
                                var seq = self.currentSequence();
                                seq.erase(offset, len) catch |err| {
                                    self.runtime.backend.cache().markTransactionFailed();
                                    return err;
                                };
                            }

                            pub fn replace(
                                self: *Self,
                                offset: u64,
                                len: u64,
                                bytes: []const u8,
                            ) Error!void {
                                try self.requireOpen();
                                var seq = self.currentSequence();
                                seq.replace(offset, len, bytes) catch |err| {
                                    self.runtime.backend.cache().markTransactionFailed();
                                    return err;
                                };
                            }

                            pub fn clear(self: *Self) Error!void {
                                try self.requireOpen();
                                var seq = self.currentSequence();
                                seq.clear() catch |err| {
                                    self.runtime.backend.cache().markTransactionFailed();
                                    return err;
                                };
                            }

                            /// Returns the canonical inline root of this weighted sequence.
                            pub fn root(self: *const Self) ?PageIdT {
                                return if (self.manager.root.isMax())
                                    null
                                else
                                    self.manager.root.get();
                            }

                            pub fn finish(self: *Self) Error!void {
                                try self.requireOpen();
                                self.envelope_editor.advanceRevision() catch |err| {
                                    self.runtime.backend.cache().markTransactionFailed();
                                    return err;
                                };
                                self.envelope_editor.finish() catch |err| {
                                    self.runtime.backend.cache().markTransactionFailed();
                                    return err;
                                };
                                self.parent_editor.finish() catch |err| {
                                    self.runtime.backend.cache().markTransactionFailed();
                                    return err;
                                };
                                self.release();
                            }

                            pub fn deinit(self: *Self) void {
                                if (!self.closed) {
                                    self.envelope_editor.invalidate();
                                    self.runtime.backend.cache().markTransactionFailed();
                                    self.release();
                                }
                            }

                            fn release(self: *Self) void {
                                self.tree.deinit();
                                self.model.deinit();
                                self.runtime.backend.allocator().destroy(self.model);
                                self.runtime.backend.allocator().destroy(self.manager);
                                self.parent_editor.rollback();
                                self.parent_editor.deinit();
                                editor_lease.release(self.runtime, self.parent_state);
                                self.closed = true;
                            }
                        };
                    }
                };

                const RtreeEditorFactory = struct {
                    pub fn get(comptime tag: []const u8) type {
                        const ChildTrait = HierarchyT.entryByTag(tag).descriptor.Trait;
                        const ChildModel = low_level_rtree.models.Paged(
                            CacheT,
                            InlineRootManager,
                            ChildTrait.Coord,
                            ChildTrait.dimensions,
                            ChildTrait.maximum_entries,
                            ChildTrait.maximum_value_size,
                            .little,
                        );
                        const ChildTree = low_level_rtree.RTree(ChildModel);
                        const is_float = @typeInfo(ChildTrait.Coord) == .float;

                        return struct {
                            const Self = @This();

                            pub const BoundingBox = ChildModel.KeyType;
                            pub const Error = ChildTree.Error ||
                                CacheT.Error ||
                                ValueEditorOwner.Error ||
                                value_envelope.Error ||
                                error{
                                    InvalidBoundingBox,
                                    EditorActive,
                                };

                            parent_editor: ValueEditorOwner,
                            envelope_editor: value_envelope.EmbeddedEditor,
                            manager: *InlineRootManager,
                            model: *ChildModel,
                            tree: ChildTree,
                            runtime: *RuntimeImpl,
                            transaction_generation: ?u64,
                            parent_state: ?*BptEditorState,
                            state: *BptEditorState,
                            closed: bool = false,

                            fn requireOpen(self: *const Self) Error!void {
                                if (self.closed or !self.runtime.active_editor) {
                                    return error.EditorInvalidated;
                                }
                                if (self.transaction_generation == null or
                                    self.runtime.backend.cache().transactionGeneration() != self.transaction_generation)
                                {
                                    return error.TransactionInactive;
                                }
                            }

                            fn requireMutable(self: *const Self) Error!void {
                                try self.requireOpen();
                                if (self.state.child_active) {
                                    return error.EditorActive;
                                }
                            }

                            fn isValidBoundingBox(mbr: BoundingBox) bool {
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

                            fn requireValidMutationBox(self: *const Self, mbr: BoundingBox) Error!void {
                                if (!isValidBoundingBox(mbr)) {
                                    self.runtime.backend.cache().markTransactionFailed();
                                    return error.InvalidBoundingBox;
                                }
                            }

                            fn SearchError(comptime CallbackT: type) type {
                                return Error || rtreeFiniteCallbackError(CallbackT);
                            }

                            pub fn raw(self: *Self, comptime value_tag: []const u8, payload: []const u8) Value {
                                return .{ .raw = .{
                                    .metadata = self.runtime.nextMetadata(value_tag),
                                    .payload = payload,
                                } };
                            }

                            pub fn embed(
                                self: *Self,
                                comptime child_tag: []const u8,
                            ) error{ChildTypeNotAllowed}!Value {
                                const parent_type_id = HierarchyT.entryByTag(tag).type_identity.type_id;
                                const child_type_id = HierarchyT.entryByTag(child_tag).type_identity.type_id;
                                if (comptime !HierarchyT.allowsChild(parent_type_id, child_type_id)) {
                                    return error.ChildTypeNotAllowed;
                                }
                                return .{ .embedded = .{
                                    .metadata = self.runtime.nextMetadata(child_tag),
                                } };
                            }

                            pub fn insert(self: *Self, mbr: BoundingBox, value: anytype) Error!void {
                                try self.requireMutable();
                                try self.requireValidMutationBox(mbr);
                                var encoded: [ChildTrait.maximum_value_size]u8 = undefined;
                                const bytes = if (@TypeOf(value) == Value) blk: {
                                    try format_hierarchy_value(&encoded, value);
                                    break :blk encoded[0..];
                                } else value;
                                return self.tree.insert(mbr, bytes) catch |err| {
                                    self.runtime.backend.cache().markTransactionFailed();
                                    return err;
                                };
                            }

                            pub fn remove(
                                self: *Self,
                                query: BoundingBox,
                                context: anytype,
                                matches: anytype,
                            ) Error!bool {
                                try self.requireMutable();
                                try self.requireValidMutationBox(query);
                                return self.tree.remove(query, context, matches) catch |err| {
                                    self.runtime.backend.cache().markTransactionFailed();
                                    return err;
                                };
                            }

                            pub fn search(
                                self: *Self,
                                query: BoundingBox,
                                context: anytype,
                                callback: anytype,
                            ) SearchError(@TypeOf(callback))!void {
                                try self.requireOpen();
                                if (!isValidBoundingBox(query)) {
                                    return error.InvalidBoundingBox;
                                }
                                return self.tree.search(query, context, callback);
                            }

                            pub fn searchIntersecting(
                                self: *Self,
                                query: BoundingBox,
                                context: anytype,
                                callback: anytype,
                            ) SearchError(@TypeOf(callback))!void {
                                try self.requireOpen();
                                if (!isValidBoundingBox(query)) {
                                    return error.InvalidBoundingBox;
                                }
                                return self.tree.searchIntersecting(query, context, callback);
                            }

                            pub fn openEmbeddedForEdit(
                                self: *Self,
                                query: BoundingBox,
                                context: anytype,
                                matches: anytype,
                                comptime child_tag: []const u8,
                            ) (ChildTree.Error || ChildError || value_envelope.Error || error{EditorActive})!?EditorForTag(child_tag) {
                                try self.requireMutable();
                                var parent_editor = (try self.tree.openValueEditor(query, context, matches)) orelse return null;
                                var parent_editor_transferred = false;
                                errdefer if (!parent_editor_transferred) {
                                    parent_editor.deinit();
                                };
                                var envelope_editor = try value_envelope.openEmbeddedMut(
                                    try parent_editor.valueMut(),
                                    HierarchyT.entryByTag(child_tag).type_identity,
                                );
                                errdefer envelope_editor.invalidate();
                                var owner = try ValueEditorOwner.init(
                                    ChildTree.ValueEditor,
                                    self.runtime.backend.allocator(),
                                    parent_editor,
                                );
                                parent_editor_transferred = true;
                                errdefer {
                                    owner.rollback();
                                    owner.deinit();
                                }
                                const payload = try envelope_editor.payloadMut();
                                var proxy = ProxyImpl{
                                    .runtime = self.runtime,
                                    .transaction_generation = self.transaction_generation,
                                };
                                return switch (comptime childKind(HierarchyT, HierarchyT.indexOfTag(child_tag))) {
                                    .bpt => try proxy.openBptEmbeddedForEdit(owner, envelope_editor, payload, child_tag, self.state),
                                    .chain_store => try proxy.openChainStoreEmbeddedForEdit(owner, envelope_editor, payload, child_tag, self.state),
                                    .weighted_sequence => try proxy.openWeightedSequenceEmbeddedForEdit(owner, envelope_editor, payload, child_tag, self.state),
                                    .rtree => try proxy.openRtreeEmbeddedForEdit(owner, envelope_editor, payload, child_tag, self.state),
                                    .slot_heap => try proxy.openSlotHeapEmbeddedForEdit(owner, envelope_editor, payload, child_tag, self.state),
                                };
                            }

                            fn EditorForTag(comptime child_tag: []const u8) type {
                                return switch (childKind(HierarchyT, HierarchyT.indexOfTag(child_tag))) {
                                    .bpt => BptEditorFactory.get(child_tag),
                                    .chain_store => ChainStoreEditorFactory.get(child_tag),
                                    .weighted_sequence => WeightedSequenceEditorFactory.get(child_tag),
                                    .rtree => RtreeEditorFactory.get(child_tag),
                                    .slot_heap => SlotHeapEditorFactory.get(child_tag),
                                };
                            }

                            /// Returns the canonical inline root of this R-tree.
                            pub fn root(self: *const Self) ?PageIdT {
                                return if (self.manager.root.isMax())
                                    null
                                else
                                    self.manager.root.get();
                            }

                            pub fn finish(self: *Self) Error!void {
                                try self.requireMutable();
                                try self.envelope_editor.advanceRevision();
                                try self.envelope_editor.finish();
                                try self.parent_editor.finish();
                                self.release();
                            }

                            pub fn deinit(self: *Self) void {
                                if (!self.closed) {
                                    self.envelope_editor.invalidate();
                                    self.runtime.backend.cache().markTransactionFailed();
                                    self.release();
                                }
                            }

                            fn release(self: *Self) void {
                                self.model.deinit();
                                self.runtime.backend.allocator().destroy(self.model);
                                self.runtime.backend.allocator().destroy(self.manager);
                                self.parent_editor.rollback();
                                self.parent_editor.deinit();
                                self.runtime.backend.allocator().destroy(self.state);
                                editor_lease.release(self.runtime, self.parent_state);
                                self.closed = true;
                            }
                        };
                    }
                };

                const SlotHeapEditorFactory = struct {
                    pub fn get(comptime tag: []const u8) type {
                        const index = comptime HierarchyT.indexOfTag(tag);
                        const ChildTrait = HierarchyT.types[index].descriptor.Trait;
                        const Child = SlotHeapChildFactory.get(index);

                        return struct {
                            const Self = @This();

                            pub const Error = Child.HeapType.Error ||
                                ValueEditorOwner.Error ||
                                value_envelope.Error ||
                                error{
                                    TopPinned,
                                    EditorActive,
                                    ChildTypeNotAllowed,
                                };

                            pub const Peek = struct {
                                const PeekSelf = @This();

                                inner: ?Child.HeapType.Peek,
                                top_pinned: *bool,

                                pub fn key(self: *const PeekSelf) Error![]const u8 {
                                    return self.inner.?.key();
                                }

                                pub fn value(self: *const PeekSelf) Error![]const u8 {
                                    return self.inner.?.value();
                                }

                                pub fn deinit(self: *PeekSelf) void {
                                    if (self.inner) |*inner| {
                                        inner.deinit();
                                        self.inner = null;
                                        self.top_pinned.* = false;
                                    }
                                }
                            };

                            parent_editor: ValueEditorOwner,
                            envelope_editor: value_envelope.EmbeddedEditor,
                            state_manager: *Child.StateManager,
                            heap_state_manager: *Child.HeapStateManagerType,
                            fsm_state_manager: *Child.FsmStateManagerType,
                            fsm_model: *Child.FsmModelType,
                            fsm_value: *Child.FsmType,
                            model: *Child.ModelType,
                            heap: Child.HeapType,
                            runtime: *RuntimeImpl,
                            transaction_generation: ?u64,
                            parent_state: ?*BptEditorState,
                            state: *BptEditorState,
                            top_pinned: bool = false,
                            closed: bool = false,

                            fn requireOpen(self: *const Self) Error!void {
                                if (self.closed or !self.runtime.active_editor) {
                                    return error.EditorInvalidated;
                                }
                                if (self.transaction_generation == null or
                                    self.runtime.backend.cache().transactionGeneration() != self.transaction_generation)
                                {
                                    return error.TransactionInactive;
                                }
                            }

                            fn requireMutable(self: *const Self) Error!void {
                                try self.requireOpen();
                                if (self.state.child_active) {
                                    return error.EditorActive;
                                }
                                if (self.top_pinned) {
                                    return error.TopPinned;
                                }
                            }

                            pub fn raw(self: *Self, comptime value_tag: []const u8, payload: []const u8) Value {
                                return .{ .raw = .{
                                    .metadata = self.runtime.nextMetadata(value_tag),
                                    .payload = payload,
                                } };
                            }

                            pub fn embed(
                                self: *Self,
                                comptime child_tag: []const u8,
                            ) error{ChildTypeNotAllowed}!Value {
                                const parent_type_id = HierarchyT.entryByTag(tag).type_identity.type_id;
                                const child_type_id = HierarchyT.entryByTag(child_tag).type_identity.type_id;
                                if (comptime !HierarchyT.allowsChild(parent_type_id, child_type_id)) {
                                    return error.ChildTypeNotAllowed;
                                }
                                return .{ .embedded = .{
                                    .metadata = self.runtime.nextMetadata(child_tag),
                                } };
                            }

                            pub fn push(self: *Self, key: []const u8, value: anytype) Error!void {
                                try self.requireMutable();
                                var encoded: [ChildTrait.maximum_value_size]u8 = undefined;
                                const bytes = if (@TypeOf(value) == Value) blk: {
                                    try format_hierarchy_value(&encoded, value);
                                    break :blk encoded[0..];
                                } else value;
                                self.heap.push(key, bytes) catch |err| {
                                    self.runtime.backend.cache().markTransactionFailed();
                                    return err;
                                };
                            }

                            pub fn pop(self: *Self) Error!void {
                                try self.requireMutable();
                                self.heap.pop() catch |err| {
                                    self.runtime.backend.cache().markTransactionFailed();
                                    return err;
                                };
                            }

                            /// Returned key/value slices borrow a pinned leaf until Peek.deinit().
                            pub fn top(self: *Self) Error!Peek {
                                try self.requireOpen();
                                if (self.top_pinned) {
                                    return error.TopPinned;
                                }
                                const inner = try self.heap.top();
                                self.top_pinned = true;
                                return .{ .inner = inner, .top_pinned = &self.top_pinned };
                            }

                            pub fn openEmbeddedForEdit(
                                self: *Self,
                                comptime child_tag: []const u8,
                            ) (Child.HeapType.Error || ChildError || value_envelope.Error || error{ EditorActive, TopPinned, ChildTypeNotAllowed })!EditorForTag(child_tag) {
                                try self.requireMutable();
                                var peek = try self.heap.mutableTop();
                                defer peek.deinit();
                                var parent_editor = try peek.editValue();
                                var parent_editor_transferred = false;
                                errdefer if (!parent_editor_transferred) {
                                    parent_editor.deinit();
                                };
                                var envelope_editor = try value_envelope.openEmbeddedMut(
                                    try parent_editor.valueMut(),
                                    HierarchyT.entryByTag(child_tag).type_identity,
                                );
                                errdefer envelope_editor.invalidate();
                                var owner = try ValueEditorOwner.init(
                                    Child.HeapType.ValueEditor,
                                    self.runtime.backend.allocator(),
                                    parent_editor,
                                );
                                parent_editor_transferred = true;
                                errdefer {
                                    owner.rollback();
                                    owner.deinit();
                                }
                                const payload = try envelope_editor.payloadMut();
                                var proxy = ProxyImpl{
                                    .runtime = self.runtime,
                                    .transaction_generation = self.transaction_generation,
                                };
                                return switch (comptime childKind(HierarchyT, HierarchyT.indexOfTag(child_tag))) {
                                    .bpt => try proxy.openBptEmbeddedForEdit(owner, envelope_editor, payload, child_tag, self.state),
                                    .chain_store => try proxy.openChainStoreEmbeddedForEdit(owner, envelope_editor, payload, child_tag, self.state),
                                    .weighted_sequence => try proxy.openWeightedSequenceEmbeddedForEdit(owner, envelope_editor, payload, child_tag, self.state),
                                    .rtree => try proxy.openRtreeEmbeddedForEdit(owner, envelope_editor, payload, child_tag, self.state),
                                    .slot_heap => try proxy.openSlotHeapEmbeddedForEdit(owner, envelope_editor, payload, child_tag, self.state),
                                };
                            }

                            fn EditorForTag(comptime child_tag: []const u8) type {
                                return switch (childKind(HierarchyT, HierarchyT.indexOfTag(child_tag))) {
                                    .bpt => BptEditorFactory.get(child_tag),
                                    .chain_store => ChainStoreEditorFactory.get(child_tag),
                                    .weighted_sequence => WeightedSequenceEditorFactory.get(child_tag),
                                    .rtree => RtreeEditorFactory.get(child_tag),
                                    .slot_heap => SlotHeapEditorFactory.get(child_tag),
                                };
                            }

                            pub fn count(self: *const Self) Error!u64 {
                                try self.requireOpen();
                                return self.heap.count();
                            }

                            pub fn isEmpty(self: *const Self) Error!bool {
                                try self.requireOpen();
                                return self.heap.isEmpty();
                            }

                            /// Returns the canonical inline root of this SlotHeap.
                            pub fn root(self: *const Self) Error!?PageIdT {
                                const root_value = self.state_manager.payload.heap.root;
                                return if (root_value.isMax()) null else root_value.get();
                            }

                            pub fn finish(self: *Self) Error!void {
                                try self.requireMutable();
                                try self.envelope_editor.advanceRevision();
                                try self.envelope_editor.finish();
                                try self.parent_editor.finish();
                                self.release();
                            }

                            pub fn deinit(self: *Self) void {
                                if (!self.closed) {
                                    std.debug.assert(!self.top_pinned);
                                    self.envelope_editor.invalidate();
                                    self.runtime.backend.cache().markTransactionFailed();
                                    self.release();
                                }
                            }

                            fn release(self: *Self) void {
                                self.model.deinit();
                                self.runtime.backend.allocator().destroy(self.model);
                                self.fsm_value.deinit();
                                self.runtime.backend.allocator().destroy(self.fsm_value);
                                self.fsm_model.deinit();
                                self.runtime.backend.allocator().destroy(self.fsm_model);
                                self.runtime.backend.allocator().destroy(self.fsm_state_manager);
                                self.runtime.backend.allocator().destroy(self.heap_state_manager);
                                self.runtime.backend.allocator().destroy(self.state_manager);
                                self.parent_editor.rollback();
                                self.parent_editor.deinit();
                                self.runtime.backend.allocator().destroy(self.state);
                                editor_lease.release(self.runtime, self.parent_state);
                                self.closed = true;
                            }
                        };
                    }
                };

                const ProxyImpl = struct {
                    const Self = @This();
                    pub const Error = ParentBinding.Error || ChildError || value_envelope.Error || error{EditorActive};
                    pub const EnvelopeValue = Value;
                    pub const ValueLease = ValueEditorOwner;

                    runtime: *RuntimeImpl,
                    transaction_generation: ?u64,

                    fn ChildBindingForTag(comptime tag: []const u8) type {
                        return component.bindingFor(
                            HierarchyT.entryByTag(tag).descriptor,
                            BackendT,
                        );
                    }

                    fn parentEditorError(comptime ParentEditorT: type) type {
                        if (!@hasDecl(ParentEditorT, "valueMut")) {
                            @compileError("embedded child parent editor must provide valueMut()");
                        }
                        const result = @typeInfo(@TypeOf(ParentEditorT.valueMut)).@"fn".return_type orelse
                            @compileError("embedded child parent editor valueMut() must return an error union");
                        return @typeInfo(result).error_union.error_set;
                    }

                    pub fn nextMetadata(
                        self: *const Self,
                        comptime tag: []const u8,
                    ) value_envelope.Metadata {
                        return self.runtime.nextMetadata(tag);
                    }

                    pub fn encodedRaw(
                        self: *const Self,
                        comptime tag: []const u8,
                        payload: []const u8,
                    ) Error!embedded.EncodedValue(ParentTrait.fixed_value_size.?) {
                        return embedded.EncodedValue(ParentTrait.fixed_value_size.?).formatRaw(
                            self.nextMetadata(tag),
                            payload,
                        );
                    }

                    pub fn encodedEmbedded(
                        self: *const Self,
                        comptime tag: []const u8,
                    ) Error!embedded.EncodedValue(ParentTrait.fixed_value_size.?) {
                        const ChildBinding = ChildBindingForTag(tag);
                        var state: ChildBinding.State = .{};
                        return embedded.EncodedValue(ParentTrait.fixed_value_size.?).formatEmbedded(
                            self.nextMetadata(tag),
                            std.mem.asBytes(&state),
                        );
                    }

                    fn requireTransaction(self: *const Self) Error!void {
                        if (self.transaction_generation == null or
                            self.runtime.backend.cache().transactionGeneration() != self.transaction_generation)
                        {
                            return error.TransactionInactive;
                        }
                    }

                    pub fn raw(self: *const Self, comptime tag: []const u8, payload: []const u8) Value {
                        return .{ .raw = .{ .metadata = self.runtime.nextMetadata(tag), .payload = payload } };
                    }

                    pub fn embed(self: *const Self, comptime tag: []const u8) Value {
                        return .{ .embedded = .{ .metadata = self.runtime.nextMetadata(tag) } };
                    }

                    pub fn insert(self: *const Self, key: []const u8, value: Value) Error!bool {
                        try self.requireTransaction();
                        var bytes: [ParentTrait.fixed_value_size.?]u8 = undefined;
                        try self.formatValue(&bytes, value);
                        return self.runtime.parent.tree.insert(key, &bytes) catch |err| {
                            self.runtime.backend.cache().markTransactionFailed();
                            return err;
                        };
                    }

                    pub fn update(self: *const Self, key: []const u8, value: Value) Error!bool {
                        try self.requireTransaction();
                        var bytes: [ParentTrait.fixed_value_size.?]u8 = undefined;
                        try self.formatValue(&bytes, value);
                        return self.runtime.parent.tree.update(key, &bytes) catch |err| {
                            self.runtime.backend.cache().markTransactionFailed();
                            return err;
                        };
                    }

                    pub fn remove(self: *const Self, key: []const u8) Error!bool {
                        try self.requireTransaction();
                        return self.runtime.parent.tree.remove(key) catch |err| {
                            self.runtime.backend.cache().markTransactionFailed();
                            return err;
                        };
                    }

                    pub fn openEmbeddedForEdit(
                        self: *const Self,
                        key: []const u8,
                        comptime tag: []const u8,
                    ) Error!?EditorForTag(tag) {
                        try self.requireTransaction();
                        if (self.runtime.active_editor) {
                            return error.EditorActive;
                        }
                        var parent_editor = (try self.runtime.parent.tree.openValueEditor(key)) orelse return null;
                        var parent_editor_transferred = false;
                        errdefer if (!parent_editor_transferred) {
                            parent_editor.deinit();
                        };
                        var envelope_editor = try value_envelope.openEmbeddedMut(
                            try parent_editor.valueMut(),
                            HierarchyT.entryByTag(tag).type_identity,
                        );
                        errdefer envelope_editor.invalidate();
                        var owner = try ValueEditorOwner.init(
                            ParentBinding.Tree.ValueEditor,
                            self.runtime.backend.allocator(),
                            parent_editor,
                        );
                        parent_editor_transferred = true;
                        errdefer {
                            owner.rollback();
                            owner.deinit();
                        }
                        const payload = try envelope_editor.payloadMut();
                        return switch (comptime childKind(HierarchyT, HierarchyT.indexOfTag(tag))) {
                            .bpt => try self.openBptEmbeddedForEdit(
                                owner,
                                envelope_editor,
                                payload,
                                tag,
                                null,
                            ),
                            .chain_store => try self.openChainStoreEmbeddedForEdit(
                                owner,
                                envelope_editor,
                                payload,
                                tag,
                                null,
                            ),
                            .weighted_sequence => try self.openWeightedSequenceEmbeddedForEdit(
                                owner,
                                envelope_editor,
                                payload,
                                tag,
                                null,
                            ),
                            .rtree => try self.openRtreeEmbeddedForEdit(
                                owner,
                                envelope_editor,
                                payload,
                                tag,
                                null,
                            ),
                            .slot_heap => try self.openSlotHeapEmbeddedForEdit(
                                owner,
                                envelope_editor,
                                payload,
                                tag,
                                null,
                            ),
                        };
                    }

                    fn ChildHandle(comptime parent_tag: []const u8, comptime ParentEditorT: type) type {
                        @setEvalBranchQuota(10_000);
                        const ParentBindingT = ChildBindingForTag(parent_tag);
                        const StorageChild = embedded.OwnedMutableChild(
                            BackendT,
                            ParentBindingT,
                            parentEditorError(ParentEditorT),
                        );

                        return struct {
                            const HandleSelf = @This();

                            pub const Error = StorageChild.Error || error{ChildTypeNotAllowed};
                            pub const StorageBinding = StorageChild.StorageBinding;

                            inner: StorageChild,
                            owner: Self,

                            pub fn proxy(self: *HandleSelf) StorageChild.StorageBinding.Proxy {
                                return self.inner.proxy();
                            }

                            pub fn reclaimPersistent(self: *HandleSelf) HandleSelf.Error!void {
                                return self.inner.reclaimPersistent();
                            }

                            pub fn finish(self: *HandleSelf) HandleSelf.Error!void {
                                return self.inner.finish();
                            }

                            pub fn deinit(self: *HandleSelf) void {
                                self.inner.deinit();
                            }

                            pub fn encodedRaw(
                                self: *const HandleSelf,
                                comptime child_tag: []const u8,
                                payload: []const u8,
                            ) HandleSelf.Error!embedded.EncodedValue(ParentBindingT.value_capacity orelse
                                @compileError("embedded parent component cannot store hierarchy values")) {
                                return self.inner.formatRaw(
                                    self.owner.nextMetadata(child_tag),
                                    payload,
                                );
                            }

                            pub fn encodedEmbedded(
                                self: *const HandleSelf,
                                comptime child_tag: []const u8,
                            ) HandleSelf.Error!embedded.EncodedValue(ParentBindingT.value_capacity orelse
                                @compileError("embedded parent component cannot store hierarchy values")) {
                                const parent_type_id = HierarchyT.entryByTag(parent_tag).type_identity.type_id;
                                const child_type_id = HierarchyT.entryByTag(child_tag).type_identity.type_id;
                                if (comptime !HierarchyT.allowsChild(parent_type_id, child_type_id)) {
                                    return error.ChildTypeNotAllowed;
                                }
                                const ChildBinding = ChildBindingForTag(child_tag);
                                var state: ChildBinding.State = .{};
                                return self.inner.formatEmbedded(
                                    self.owner.nextMetadata(child_tag),
                                    std.mem.asBytes(&state),
                                );
                            }

                            /// Transfers a native value editor from this child's proxy
                            /// into one of its registered children.
                            pub fn openChild(
                                self: *const HandleSelf,
                                parent_editor: anytype,
                                comptime child_tag: []const u8,
                            ) @TypeOf(self.owner.openNestedChild(
                                parent_tag,
                                parent_editor,
                                child_tag,
                            )) {
                                return self.owner.openNestedChild(
                                    parent_tag,
                                    parent_editor,
                                    child_tag,
                                );
                            }
                        };
                    }

                    fn openChildStorage(
                        self: *const Self,
                        parent_editor: anytype,
                        comptime tag: []const u8,
                    ) (Error || parentEditorError(@TypeOf(parent_editor)))!embedded.OwnedMutableChild(
                        BackendT,
                        ChildBindingForTag(tag),
                        parentEditorError(@TypeOf(parent_editor)),
                    ) {
                        try self.requireTransaction();
                        var owned_parent_editor = parent_editor;
                        var transferred = false;
                        errdefer if (!transferred) {
                            owned_parent_editor.deinit();
                        };
                        var envelope_editor = try value_envelope.openEmbeddedMut(
                            try owned_parent_editor.valueMut(),
                            HierarchyT.entryByTag(tag).type_identity,
                        );
                        errdefer envelope_editor.invalidate();
                        const ChildBinding = ChildBindingForTag(tag);
                        const Child = embedded.OwnedMutableChild(
                            BackendT,
                            ChildBinding,
                            parentEditorError(@TypeOf(parent_editor)),
                        );
                        const child = try Child.init(
                            self.runtime.backend,
                            try envelope_editor.payloadMut(),
                            envelope_editor,
                            owned_parent_editor,
                            self.runtime.childPageKinds(HierarchyT.indexOfTag(tag)),
                            .{},
                        );
                        transferred = true;
                        return child;
                    }

                    /// Opens a registered root child through its component-owned
                    /// StorageBinding. The returned handle exposes the native proxy
                    /// and can open nested hierarchy children.
                    pub fn openChild(
                        self: *const Self,
                        parent_editor: anytype,
                        comptime tag: []const u8,
                    ) (Error || parentEditorError(@TypeOf(parent_editor)))!ChildHandle(
                        tag,
                        @TypeOf(parent_editor),
                    ) {
                        return .{
                            .inner = try self.openChildStorage(parent_editor, tag),
                            .owner = self.*,
                        };
                    }

                    fn openNestedChild(
                        self: *const Self,
                        comptime parent_tag: []const u8,
                        parent_editor: anytype,
                        comptime child_tag: []const u8,
                    ) (Error || parentEditorError(@TypeOf(parent_editor)) || error{ChildTypeNotAllowed})!ChildHandle(
                        child_tag,
                        @TypeOf(parent_editor),
                    ) {
                        const parent_type_id = HierarchyT.entryByTag(parent_tag).type_identity.type_id;
                        const child_type_id = HierarchyT.entryByTag(child_tag).type_identity.type_id;
                        if (comptime !HierarchyT.allowsChild(parent_type_id, child_type_id)) {
                            return error.ChildTypeNotAllowed;
                        }
                        return .{
                            .inner = try self.openChildStorage(parent_editor, child_tag),
                            .owner = self.*,
                        };
                    }

                    /// Opens a BPT child by key for callers still using the
                    /// pre-generic selection API.
                    pub fn openEmbeddedStorageForEdit(
                        self: *const Self,
                        key: []const u8,
                        comptime tag: []const u8,
                    ) Error!?embedded.OwnedMutableChild(
                        BackendT,
                        ChildBindingForTag(tag),
                        ParentBinding.Error || ChildError,
                    ) {
                        const parent_editor = (try self.runtime.parent.tree.openValueEditor(key)) orelse return null;
                        return self.openChildStorage(parent_editor, tag);
                    }

                    pub fn EditorForTag(comptime tag: []const u8) type {
                        return switch (childKind(HierarchyT, HierarchyT.indexOfTag(tag))) {
                            .bpt => BptEditorFactory.get(tag),
                            .chain_store => ChainStoreEditorFactory.get(tag),
                            .weighted_sequence => WeightedSequenceEditorFactory.get(tag),
                            .rtree => RtreeEditorFactory.get(tag),
                            .slot_heap => SlotHeapEditorFactory.get(tag),
                        };
                    }

                    pub fn openEmbeddedForEditLease(
                        self: *const Self,
                        parent_editor: ValueEditorOwner,
                        envelope_editor: value_envelope.EmbeddedEditor,
                        payload: []u8,
                        comptime tag: []const u8,
                    ) Error!EditorForTag(tag) {
                        return switch (comptime childKind(HierarchyT, HierarchyT.indexOfTag(tag))) {
                            .bpt => try self.openBptEmbeddedForEdit(parent_editor, envelope_editor, payload, tag, null),
                            .chain_store => try self.openChainStoreEmbeddedForEdit(parent_editor, envelope_editor, payload, tag, null),
                            .weighted_sequence => try self.openWeightedSequenceEmbeddedForEdit(parent_editor, envelope_editor, payload, tag, null),
                            .rtree => try self.openRtreeEmbeddedForEdit(parent_editor, envelope_editor, payload, tag, null),
                            .slot_heap => try self.openSlotHeapEmbeddedForEdit(parent_editor, envelope_editor, payload, tag, null),
                        };
                    }

                    pub fn openBptEmbeddedForEdit(
                        self: *const Self,
                        parent_editor: ValueEditorOwner,
                        envelope_editor: value_envelope.EmbeddedEditor,
                        payload: []u8,
                        comptime tag: []const u8,
                        parent_state: ?*BptEditorState,
                    ) Error!BptEditorFactory.get(tag) {
                        if (payload.len != @sizeOf(PackedRoot)) {
                            return error.BadPayloadLength;
                        }
                        const root: *PackedRoot = @ptrCast(payload.ptr);
                        const ChildTrait = HierarchyT.entryByTag(tag).descriptor.Trait;
                        const manager = try self.runtime.backend.allocator().create(InlineRootManager);
                        errdefer self.runtime.backend.allocator().destroy(manager);
                        manager.* = InlineRootManager.init(self.runtime.backend.cache(), root);
                        const model = try self.runtime.backend.allocator().create(
                            low_level_bpt.models.PagedModel(
                                CacheT,
                                InlineRootManager,
                                ChildTrait.compare,
                                ChildTrait.CompareContext,
                            ),
                        );
                        errdefer self.runtime.backend.allocator().destroy(model);
                        model.* = try low_level_bpt.models.PagedModel(
                            CacheT,
                            InlineRootManager,
                            ChildTrait.compare,
                            ChildTrait.CompareContext,
                        ).init(
                            self.runtime.backend.cache(),
                            manager,
                            .{
                                .maximum_key_size = ChildTrait.maximum_key_size,
                                .maximum_value_size = ChildTrait.maximum_value_size,
                                .fixed_value_size = ChildTrait.fixed_value_size,
                                .leaf_page_kind = self.runtime.childPageKinds(HierarchyT.indexOfTag(tag)).kindAt(0).?,
                                .inode_page_kind = self.runtime.childPageKinds(HierarchyT.indexOfTag(tag)).kindAt(1).?,
                            },
                            {},
                        );
                        errdefer model.deinit();
                        const state = try self.runtime.backend.allocator().create(BptEditorState);
                        errdefer self.runtime.backend.allocator().destroy(state);
                        state.* = .{};
                        editor_lease.activate(self.runtime, parent_state);
                        return .{
                            .parent_editor = parent_editor,
                            .envelope_editor = envelope_editor,
                            .manager = manager,
                            .model = model,
                            .tree = .init(model, ChildTrait.rebalance_policy),
                            .runtime = self.runtime,
                            .transaction_generation = self.transaction_generation,
                            .parent_state = parent_state,
                            .state = state,
                        };
                    }

                    pub fn openChainStoreEmbeddedForEdit(
                        self: *const Self,
                        parent_editor: ValueEditorOwner,
                        envelope_editor: value_envelope.EmbeddedEditor,
                        payload: []u8,
                        comptime tag: []const u8,
                        parent_state: ?*BptEditorState,
                    ) Error!ChainStoreEditorFactory.get(tag) {
                        if (payload.len != @sizeOf(ChainStoreState)) {
                            return error.BadPayloadLength;
                        }
                        const chain_payload: *ChainStoreState = @ptrCast(payload.ptr);
                        const manager = try self.runtime.backend.allocator().create(InlineChainStoreManager);
                        errdefer self.runtime.backend.allocator().destroy(manager);
                        manager.* = InlineChainStoreManager.init(self.runtime.backend.cache(), chain_payload);
                        const ChainBlob = fullaz.storage.chain_store.Blob(
                            CacheT,
                            InlineChainStoreManager,
                            .little,
                        );
                        var blob = ChainBlob.init(
                            self.runtime.backend.cache(),
                            manager,
                            .{ .chunk_page_kind = self.runtime.childPageKinds(HierarchyT.indexOfTag(tag)).kindAt(0).? },
                        );
                        errdefer blob.deinit();
                        try blob.open();
                        editor_lease.activate(self.runtime, parent_state);
                        return .{
                            .parent_editor = parent_editor,
                            .envelope_editor = envelope_editor,
                            .manager = manager,
                            .blob = blob,
                            .runtime = self.runtime,
                            .transaction_generation = self.transaction_generation,
                            .parent_state = parent_state,
                        };
                    }

                    pub fn openWeightedSequenceEmbeddedForEdit(
                        self: *const Self,
                        parent_editor: ValueEditorOwner,
                        envelope_editor: value_envelope.EmbeddedEditor,
                        payload: []u8,
                        comptime tag: []const u8,
                        parent_state: ?*BptEditorState,
                    ) Error!WeightedSequenceEditorFactory.get(tag) {
                        if (payload.len != @sizeOf(PackedRoot)) {
                            return error.BadPayloadLength;
                        }
                        const root: *PackedRoot = @ptrCast(payload.ptr);
                        const ChildTrait = HierarchyT.entryByTag(tag).descriptor.Trait;
                        const ChildModel = weighted_bpt.models.paged.PagedModel(
                            CacheT,
                            InlineRootManager,
                            u64,
                            void,
                        );
                        const ChildTree = weighted_bpt.WeightedBpt(ChildModel);
                        const manager = try self.runtime.backend.allocator().create(InlineRootManager);
                        errdefer self.runtime.backend.allocator().destroy(manager);
                        manager.* = InlineRootManager.init(self.runtime.backend.cache(), root);
                        const model = try self.runtime.backend.allocator().create(ChildModel);
                        errdefer self.runtime.backend.allocator().destroy(model);
                        model.* = ChildModel.init(
                            self.runtime.backend.cache(),
                            manager,
                            .{
                                .maximum_value_size = ChildTrait.maximum_chunk_size,
                                .leaf_page_kind = self.runtime.childPageKinds(HierarchyT.indexOfTag(tag)).kindAt(0).?,
                                .inode_page_kind = self.runtime.childPageKinds(HierarchyT.indexOfTag(tag)).kindAt(1).?,
                            },
                        );
                        errdefer model.deinit();
                        editor_lease.activate(self.runtime, parent_state);
                        return .{
                            .parent_editor = parent_editor,
                            .envelope_editor = envelope_editor,
                            .manager = manager,
                            .model = model,
                            .tree = ChildTree.init(model, .neighbor_share),
                            .runtime = self.runtime,
                            .transaction_generation = self.transaction_generation,
                            .parent_state = parent_state,
                        };
                    }

                    pub fn openRtreeEmbeddedForEdit(
                        self: *const Self,
                        parent_editor: ValueEditorOwner,
                        envelope_editor: value_envelope.EmbeddedEditor,
                        payload: []u8,
                        comptime tag: []const u8,
                        parent_state: ?*BptEditorState,
                    ) Error!RtreeEditorFactory.get(tag) {
                        if (payload.len != @sizeOf(PackedRoot)) {
                            return error.BadPayloadLength;
                        }
                        const root: *PackedRoot = @ptrCast(payload.ptr);
                        const ChildTrait = HierarchyT.entryByTag(tag).descriptor.Trait;
                        const ChildModel = low_level_rtree.models.Paged(
                            CacheT,
                            InlineRootManager,
                            ChildTrait.Coord,
                            ChildTrait.dimensions,
                            ChildTrait.maximum_entries,
                            ChildTrait.maximum_value_size,
                            .little,
                        );
                        const ChildTree = low_level_rtree.RTree(ChildModel);
                        const manager = try self.runtime.backend.allocator().create(InlineRootManager);
                        errdefer self.runtime.backend.allocator().destroy(manager);
                        manager.* = InlineRootManager.init(self.runtime.backend.cache(), root);
                        const model = try self.runtime.backend.allocator().create(ChildModel);
                        errdefer self.runtime.backend.allocator().destroy(model);
                        model.* = try ChildModel.init(
                            self.runtime.backend.cache(),
                            manager,
                            .{
                                .leaf_page_kind = self.runtime.childPageKinds(HierarchyT.indexOfTag(tag)).kindAt(0).?,
                                .inode_page_kind = self.runtime.childPageKinds(HierarchyT.indexOfTag(tag)).kindAt(1).?,
                            },
                        );
                        errdefer model.deinit();
                        const state = try self.runtime.backend.allocator().create(BptEditorState);
                        errdefer self.runtime.backend.allocator().destroy(state);
                        state.* = .{};
                        editor_lease.activate(self.runtime, parent_state);
                        return .{
                            .parent_editor = parent_editor,
                            .envelope_editor = envelope_editor,
                            .manager = manager,
                            .model = model,
                            .tree = ChildTree.init(model),
                            .runtime = self.runtime,
                            .transaction_generation = self.transaction_generation,
                            .parent_state = parent_state,
                            .state = state,
                        };
                    }

                    pub fn openSlotHeapEmbeddedForEdit(
                        self: *const Self,
                        parent_editor: ValueEditorOwner,
                        envelope_editor: value_envelope.EmbeddedEditor,
                        payload: []u8,
                        comptime tag: []const u8,
                        parent_state: ?*BptEditorState,
                    ) Error!SlotHeapEditorFactory.get(tag) {
                        const index = comptime HierarchyT.indexOfTag(tag);
                        const ChildTrait = HierarchyT.types[index].descriptor.Trait;
                        const Child = SlotHeapChildFactory.get(index);
                        if (payload.len != @sizeOf(Child.PayloadType)) {
                            return error.BadPayloadLength;
                        }
                        const storage: *Child.PayloadType = @ptrCast(payload.ptr);
                        const state_manager = try self.runtime.backend.allocator().create(Child.StateManager);
                        errdefer self.runtime.backend.allocator().destroy(state_manager);
                        state_manager.* = Child.StateManager.init(self.runtime.backend.cache(), storage);
                        const heap_state_manager = try self.runtime.backend.allocator().create(
                            Child.HeapStateManagerType,
                        );
                        errdefer self.runtime.backend.allocator().destroy(heap_state_manager);
                        heap_state_manager.* = Child.HeapStateManagerType.init(state_manager);
                        const fsm_state_manager = try self.runtime.backend.allocator().create(
                            Child.FsmStateManagerType,
                        );
                        errdefer self.runtime.backend.allocator().destroy(fsm_state_manager);
                        fsm_state_manager.* = Child.FsmStateManagerType.init(state_manager);
                        const fsm_model = try self.runtime.backend.allocator().create(Child.FsmModelType);
                        errdefer self.runtime.backend.allocator().destroy(fsm_model);
                        fsm_model.* = Child.FsmModelType.init(
                            self.runtime.backend.cache(),
                            fsm_state_manager,
                            ChildTrait.size_class_policy,
                            .{ .page_kind = self.runtime.childPageKinds(index).kindAt(2).? },
                        );
                        const fsm_value = try self.runtime.backend.allocator().create(Child.FsmType);
                        errdefer self.runtime.backend.allocator().destroy(fsm_value);
                        fsm_value.* = Child.FsmType.init(fsm_model);
                        const model = try self.runtime.backend.allocator().create(Child.ModelType);
                        errdefer self.runtime.backend.allocator().destroy(model);
                        model.* = try Child.ModelType.init(
                            self.runtime.backend.cache(),
                            heap_state_manager,
                            fsm_value,
                            .{
                                .key_size = ChildTrait.maximum_key_size,
                                .maximum_value_size = ChildTrait.maximum_value_size,
                                .comparator_id = ChildTrait.comparator_id,
                                .leaf_page_kind = self.runtime.childPageKinds(index).kindAt(0).?,
                                .inode_page_kind = self.runtime.childPageKinds(index).kindAt(1).?,
                                .maximum_level = ChildTrait.maximum_level,
                            },
                            {},
                        );
                        errdefer model.deinit();
                        const state = try self.runtime.backend.allocator().create(BptEditorState);
                        errdefer self.runtime.backend.allocator().destroy(state);
                        state.* = .{};
                        editor_lease.activate(self.runtime, parent_state);
                        return .{
                            .parent_editor = parent_editor,
                            .envelope_editor = envelope_editor,
                            .state_manager = state_manager,
                            .heap_state_manager = heap_state_manager,
                            .fsm_state_manager = fsm_state_manager,
                            .fsm_model = fsm_model,
                            .fsm_value = fsm_value,
                            .model = model,
                            .heap = Child.HeapType.init(model),
                            .runtime = self.runtime,
                            .transaction_generation = self.transaction_generation,
                            .parent_state = parent_state,
                            .state = state,
                        };
                    }

                    pub fn formatValue(self: *const Self, bytes: []u8, value: Value) value_envelope.Error!void {
                        _ = self;
                        return format_hierarchy_value(bytes, value);
                    }
                };

                const format_hierarchy_value = struct {
                    fn format(bytes: []u8, value: Value) value_envelope.Error!void {
                        switch (value) {
                            .raw => |raw_value| {
                                try value_envelope.formatRaw(
                                    bytes,
                                    raw_value.metadata,
                                    raw_value.payload,
                                );
                            },
                            .embedded => |embedded_value| {
                                var root = PackedRoot.init(PackedRoot.max);
                                var chain_payload: ChainStoreState = .{};
                                inline for (HierarchyT.types, 0..) |entry, index| {
                                    const identity = entry.type_identity;
                                    if (embedded_value.metadata.registry_id == identity.registry_id and
                                        embedded_value.metadata.type_id == identity.type_id and
                                        embedded_value.metadata.type_version == identity.type_version and
                                        embedded_value.metadata.metadata_format_version == identity.metadata_format_version)
                                    {
                                        const payload = if (comptime childKind(HierarchyT, index) == .slot_heap) blk: {
                                            var slot_heap_payload = SlotHeapChildFactory.get(index).emptyPayload();
                                            break :blk std.mem.asBytes(&slot_heap_payload);
                                        } else switch (childKind(HierarchyT, index)) {
                                            .bpt, .rtree, .weighted_sequence => std.mem.asBytes(&root),
                                            .chain_store => std.mem.asBytes(&chain_payload),
                                            .slot_heap => unreachable,
                                        };
                                        return value_envelope.formatEmbedded(
                                            bytes,
                                            embedded_value.metadata,
                                            payload,
                                        );
                                    }
                                }
                                return error.IncorrectType;
                            },
                        }
                    }
                }.format;
            };
            const ProxyImpl = EditorTypes.ProxyImpl;

            const BindingT = struct {
                pub const Runtime = RuntimeImpl;
                pub const Proxy = ProxyImpl;
                pub const ConstProxy = ConstProxyImpl;
                pub const InitOptions = ParentBinding.InitOptions;
                pub const TransactionState = struct {
                    parent: ParentBinding.TransactionState,
                    next_instance_id: u64,
                };
                pub const Error = ParentBinding.Error || ChildError || value_envelope.Error || error{EditorActive};
                pub const StaticMetadata = struct {
                    pub const Storage = extern struct {
                        parent: ParentBinding.StaticMetadata.Storage,
                        next_instance_id: PackedInt(u64, .little),
                    };
                    pub const Error = ParentBinding.StaticMetadata.Error || error{BadMetadata};

                    pub fn capture(runtime: *const RuntimeImpl) Storage {
                        return .{
                            .parent = ParentBinding.StaticMetadata.capture(&runtime.parent),
                            .next_instance_id = PackedInt(u64, .little).init(runtime.next_instance_id),
                        };
                    }

                    pub fn restore(runtime: *RuntimeImpl, storage: *const Storage) void {
                        ParentBinding.StaticMetadata.restore(&runtime.parent, &storage.parent);
                        runtime.next_instance_id = storage.next_instance_id.get();
                    }

                    pub fn validate(storage: *const Storage, page_count: usize) @This().Error!void {
                        try ParentBinding.StaticMetadata.validate(&storage.parent, page_count);
                        if (storage.next_instance_id.get() == 0) {
                            return error.BadMetadata;
                        }
                    }
                };
                pub const DynamicMetadata = struct {
                    pub const format_version = ParentBinding.DynamicMetadata.format_version;
                    pub const known_tags = ParentBinding.DynamicMetadata.known_tags;
                    pub const repeated_tags = ParentBinding.DynamicMetadata.repeated_tags;
                    pub const Error = ParentBinding.DynamicMetadata.Error;

                    pub fn restore(runtime: *RuntimeImpl, payload: []const u8, page_count: usize) @This().Error!void {
                        return ParentBinding.DynamicMetadata.restore(&runtime.parent, payload, page_count);
                    }

                    pub fn encodeKnown(runtime: *const RuntimeImpl, writer: *tagged.Writer) @This().Error!void {
                        return ParentBinding.DynamicMetadata.encodeKnown(&runtime.parent, writer);
                    }
                };

                pub fn initRuntime(
                    runtime: *RuntimeImpl,
                    backend: *BackendT,
                    page_kinds: component.PageKindRange,
                    options: InitOptions,
                ) Error!void {
                    if (page_kinds.count != hierarchy_page_kind_count) {
                        return error.InvalidPageKinds;
                    }
                    runtime.backend = backend;
                    runtime.page_kinds = page_kinds;
                    runtime.type_page_kinds = .{
                        .base = @intCast(@as(u32, page_kinds.base) + ParentTrait.page_kind_count),
                        .count = @intCast(childPageKindCount(HierarchyT)),
                    };
                    runtime.active_editor = false;
                    runtime.next_instance_id = 1;
                    runtime.aggregate_next_instance_id = null;
                    try ParentBinding.initRuntime(&runtime.parent, backend, runtime.parentPageKinds(), options);
                    runtime.const_runtime = .{
                        .parent = &runtime.parent,
                        .backend = backend,
                        .type_page_kinds = runtime.type_page_kinds,
                    };
                    runtime.const_proxy = ConstProxy.init(&runtime.const_runtime);
                }

                /// Initializes this envelope core with owner and nominal-type
                /// ranges assigned independently by a hierarchy aggregate.
                pub fn initAggregateRuntime(
                    runtime: *RuntimeImpl,
                    backend: *BackendT,
                    owner_page_kinds: component.PageKindRange,
                    type_page_kinds: component.PageKindRange,
                    options: InitOptions,
                ) Error!void {
                    if (owner_page_kinds.count != ParentTrait.page_kind_count or
                        type_page_kinds.count != childPageKindCount(HierarchyT))
                    {
                        return error.InvalidPageKinds;
                    }
                    runtime.backend = backend;
                    runtime.page_kinds = owner_page_kinds;
                    runtime.type_page_kinds = type_page_kinds;
                    runtime.active_editor = false;
                    runtime.next_instance_id = 1;
                    runtime.aggregate_next_instance_id = null;
                    try ParentBinding.initRuntime(&runtime.parent, backend, owner_page_kinds, options);
                    runtime.const_runtime = .{
                        .parent = &runtime.parent,
                        .backend = backend,
                        .type_page_kinds = runtime.type_page_kinds,
                    };
                    runtime.const_proxy = ConstProxy.init(&runtime.const_runtime);
                }

                /// Initializes only the shared envelope state. Aggregate owners
                /// with a non-BPT parent use this because their native runtime
                /// already owns the owner page kinds.
                pub fn initAggregateEnvelopeRuntime(
                    runtime: *RuntimeImpl,
                    backend: *BackendT,
                    owner_page_kinds: component.PageKindRange,
                    type_page_kinds: component.PageKindRange,
                ) Error!void {
                    if (type_page_kinds.count != childPageKindCount(HierarchyT)) {
                        return error.InvalidPageKinds;
                    }
                    runtime.backend = backend;
                    runtime.page_kinds = owner_page_kinds;
                    runtime.type_page_kinds = type_page_kinds;
                    runtime.active_editor = false;
                    runtime.next_instance_id = 1;
                    runtime.aggregate_next_instance_id = null;
                }

                pub fn deinitRuntime(runtime: *RuntimeImpl) void {
                    requireTransactionIdle(runtime) catch
                        @panic("hierarchyStore runtime deinitialized with an active value editor");
                    ParentBinding.deinitRuntime(&runtime.parent);
                    runtime.* = undefined;
                }

                pub fn captureTransactionState(runtime: *const RuntimeImpl) TransactionState {
                    return .{
                        .parent = ParentBinding.captureTransactionState(&runtime.parent),
                        .next_instance_id = runtime.next_instance_id,
                    };
                }

                pub fn restoreTransactionState(runtime: *RuntimeImpl, state: TransactionState) void {
                    ParentBinding.restoreTransactionState(&runtime.parent, state.parent);
                    runtime.next_instance_id = state.next_instance_id;
                }

                pub fn requireTransactionIdle(runtime: *const RuntimeImpl) Error!void {
                    if (runtime.active_editor) {
                        return error.EditorActive;
                    }
                    try ParentBinding.requireTransactionIdle(&runtime.parent);
                }

                pub fn proxy(runtime: *RuntimeImpl) ProxyImpl {
                    return .{
                        .runtime = runtime,
                        .transaction_generation = runtime.backend.cache().transactionGeneration(),
                    };
                }

                pub fn proxyConst(runtime: *const RuntimeImpl) *const ConstProxy {
                    return &runtime.const_proxy;
                }

                pub fn reclaimPersistent(runtime: *RuntimeImpl) Error!void {
                    try requireTransactionIdle(runtime);
                    try ParentBinding.reclaimPersistent(&runtime.parent);
                }

                pub fn hierarchyValueScanner(comptime CollectorT: type) CollectorT.ValueScanner {
                    return RuntimeImpl.valueScanner(CollectorT);
                }

                pub fn registerTypeScanners(
                    runtime: *const RuntimeImpl,
                    collector: anytype,
                ) @TypeOf(collector.*).Error!void {
                    const CollectorT = @TypeOf(collector.*);
                    inline for (0..HierarchyT.type_count) |index| {
                        const kinds = runtime.childPageKinds(index);
                        if (comptime childKind(HierarchyT, index) == .bpt) {
                            try collector.registerForCycle(kinds.kindAt(0).?, 1, runtime, RuntimeImpl.bptChildLeafScanner(CollectorT, index), RuntimeImpl.valueScanner(CollectorT));
                            try collector.registerForCycle(kinds.kindAt(1).?, 1, runtime, RuntimeImpl.bptChildInodeScanner(CollectorT, index), null);
                        } else if (comptime childKind(HierarchyT, index) == .chain_store) {
                            try collector.registerForCycle(kinds.kindAt(0).?, 1, runtime, RuntimeImpl.chainStoreChildScanner(CollectorT, index), null);
                        } else if (comptime childKind(HierarchyT, index) == .rtree) {
                            try collector.registerForCycle(kinds.kindAt(0).?, 1, runtime, RuntimeImpl.rtreeChildLeafScanner(CollectorT, index), RuntimeImpl.valueScanner(CollectorT));
                            try collector.registerForCycle(kinds.kindAt(1).?, 1, runtime, RuntimeImpl.rtreeChildInodeScanner(CollectorT, index), null);
                        } else if (comptime childKind(HierarchyT, index) == .slot_heap) {
                            try collector.registerForCycle(kinds.kindAt(0).?, 1, runtime, RuntimeImpl.slotHeapChildLeafScanner(CollectorT, index), RuntimeImpl.valueScanner(CollectorT));
                            try collector.registerForCycle(kinds.kindAt(1).?, 1, runtime, RuntimeImpl.slotHeapChildInodeScanner(CollectorT, index), null);
                            try collector.registerForCycle(kinds.kindAt(2).?, 1, runtime, RuntimeImpl.slotHeapChildFsmSlabScanner(CollectorT, index), null);
                        } else {
                            try collector.registerForCycle(kinds.kindAt(0).?, 1, runtime, RuntimeImpl.weightedSequenceChildLeafScanner(CollectorT, index), null);
                            try collector.registerForCycle(kinds.kindAt(1).?, 1, runtime, RuntimeImpl.weightedSequenceChildInodeScanner(CollectorT, index), null);
                        }
                    }
                }

                pub fn Gc(comptime CollectorT: type) type {
                    return struct {
                        pub const RootsError = std.mem.Allocator.Error;
                        pub const RegisterError = CollectorT.Error;

                        pub fn appendRoots(
                            runtime: *const RuntimeImpl,
                            allocator: std.mem.Allocator,
                            roots: *std.ArrayList(CollectorT.PageId),
                        ) RootsError!void {
                            if (!runtime.parent.state.root.isMax()) {
                                try roots.append(allocator, runtime.parent.state.root.get());
                            }
                        }

                        pub fn registerScanners(runtime: *const RuntimeImpl, collector: *CollectorT) RegisterError!void {
                            const parent_leaf = runtime.parentPageKinds().kindAt(0).?;
                            const parent_inode = runtime.parentPageKinds().kindAt(1).?;
                            try collector.registerForCycle(
                                parent_leaf,
                                1,
                                runtime,
                                gc.scanners.method(CollectorT, RuntimeImpl, RuntimeImpl.scanParentLeaf),
                                RuntimeImpl.valueScanner(CollectorT),
                            );
                            try collector.registerForCycle(
                                parent_inode,
                                1,
                                &runtime.parent.tree,
                                gc.scanners.method(CollectorT, ParentBinding.Tree, ParentBinding.Tree.scanInodeRefs),
                                null,
                            );
                            inline for (0..HierarchyT.type_count) |index| {
                                const kinds = runtime.childPageKinds(index);
                                if (comptime childKind(HierarchyT, index) == .bpt) {
                                    try collector.registerForCycle(
                                        kinds.kindAt(0).?,
                                        1,
                                        runtime,
                                        RuntimeImpl.bptChildLeafScanner(CollectorT, index),
                                        RuntimeImpl.valueScanner(CollectorT),
                                    );
                                    try collector.registerForCycle(
                                        kinds.kindAt(1).?,
                                        1,
                                        runtime,
                                        RuntimeImpl.bptChildInodeScanner(CollectorT, index),
                                        null,
                                    );
                                } else if (comptime childKind(HierarchyT, index) == .chain_store) {
                                    try collector.registerForCycle(
                                        kinds.kindAt(0).?,
                                        1,
                                        runtime,
                                        RuntimeImpl.chainStoreChildScanner(CollectorT, index),
                                        null,
                                    );
                                } else if (comptime childKind(HierarchyT, index) == .rtree) {
                                    try collector.registerForCycle(
                                        kinds.kindAt(0).?,
                                        1,
                                        runtime,
                                        RuntimeImpl.rtreeChildLeafScanner(CollectorT, index),
                                        RuntimeImpl.valueScanner(CollectorT),
                                    );
                                    try collector.registerForCycle(
                                        kinds.kindAt(1).?,
                                        1,
                                        runtime,
                                        RuntimeImpl.rtreeChildInodeScanner(CollectorT, index),
                                        null,
                                    );
                                } else if (comptime childKind(HierarchyT, index) == .slot_heap) {
                                    try collector.registerForCycle(
                                        kinds.kindAt(0).?,
                                        1,
                                        runtime,
                                        RuntimeImpl.slotHeapChildLeafScanner(CollectorT, index),
                                        RuntimeImpl.valueScanner(CollectorT),
                                    );
                                    try collector.registerForCycle(
                                        kinds.kindAt(1).?,
                                        1,
                                        runtime,
                                        RuntimeImpl.slotHeapChildInodeScanner(CollectorT, index),
                                        null,
                                    );
                                    try collector.registerForCycle(
                                        kinds.kindAt(2).?,
                                        1,
                                        runtime,
                                        RuntimeImpl.slotHeapChildFsmSlabScanner(CollectorT, index),
                                        null,
                                    );
                                } else {
                                    try collector.registerForCycle(
                                        kinds.kindAt(0).?,
                                        1,
                                        runtime,
                                        RuntimeImpl.weightedSequenceChildLeafScanner(CollectorT, index),
                                        null,
                                    );
                                    try collector.registerForCycle(
                                        kinds.kindAt(1).?,
                                        1,
                                        runtime,
                                        RuntimeImpl.weightedSequenceChildInodeScanner(CollectorT, index),
                                        null,
                                    );
                                }
                            }
                        }
                    };
                }
            };

            comptime component.assertStaticMetadata(BindingT, BindingT.StaticMetadata);
            return BindingT;
        }
    };
    return component.descriptor(Trait);
}

fn SinkVisitor(comptime CollectorT: type) type {
    return struct {
        const Abort = error{Abort};
        sink: CollectorT.ReferenceSink,
        sink_error: ?CollectorT.Error = null,

        pub fn visit(self: *@This(), page_id: CollectorT.PageId) Abort!void {
            self.sink.visit(page_id) catch |err| {
                self.sink_error = err;
                return error.Abort;
            };
        }

        pub fn hasValueScanner(self: *const @This()) bool {
            return self.sink.hasValueScanner();
        }

        pub fn visitValue(self: *@This(), value: []const u8) Abort!void {
            self.sink.visitValue(value) catch |err| {
                self.sink_error = err;
                return error.Abort;
            };
        }
    };
}

fn validate(comptime HierarchyT: type, comptime parent_descriptor: component.Descriptor) void {
    if (!@hasDecl(HierarchyT, "types") or !@hasDecl(HierarchyT, "entryByTag")) {
        @compileError("fullaz-db hierarchyStore requires a fullaz-db Hierarchy type");
    }
    if (!@hasDecl(parent_descriptor.Trait, "fixed_value_size") or parent_descriptor.Trait.fixed_value_size == null) {
        @compileError("fullaz-db hierarchyStore parent BPT requires fixed_value_size");
    }
    if (parent_descriptor.Trait.fixed_value_size.? < value_envelope.envelope_byte_size + 1) {
        @compileError("fullaz-db hierarchyStore parent fixed_value_size cannot hold an embedded child envelope");
    }
    inline for (HierarchyT.types) |entry| {
        const Trait = entry.descriptor.Trait;
        switch (childKindForTrait(Trait)) {
            .bpt => {
                if (Trait.CompareContext != void) {
                    @compileError("fullaz-db hierarchyStore currently requires void BPT child compare contexts");
                }
            },
            .chain_store => {},
            .rtree => {},
            .weighted_sequence => {
                if (@TypeOf(Trait.maximum_chunk_size) != usize) {
                    @compileError("fullaz-db hierarchyStore weightedSequence child maximum_chunk_size must be usize");
                }
                if (Trait.maximum_chunk_size == 0) {
                    @compileError("fullaz-db hierarchyStore weightedSequence child maximum_chunk_size must be non-zero");
                }
            },
            .slot_heap => {
                if (Trait.CompareContext != void) {
                    @compileError("fullaz-db hierarchyStore currently requires void SlotHeap child compare contexts");
                }
            },
        }
    }
}

fn childKind(comptime HierarchyT: type, comptime index: usize) ChildKind {
    return childKindForTrait(HierarchyT.types[index].descriptor.Trait);
}

fn maximumChildPayloadSize(comptime HierarchyT: type, comptime PageIdT: type) usize {
    var maximum: usize = 0;
    inline for (HierarchyT.types) |entry| {
        maximum = @max(maximum, childPayloadSize(entry.descriptor.Trait, PageIdT));
    }
    return maximum;
}

fn validateBptChildEnvelopeCapacities(comptime HierarchyT: type, comptime PageIdT: type) void {
    inline for (HierarchyT.types, 0..) |entry, parent_index| {
        const Trait = entry.descriptor.Trait;
        if (childKindForTrait(Trait) != .bpt) {
            continue;
        }
        const required = value_envelope.envelope_byte_size +
            maximumAllowedChildPayloadSize(HierarchyT, parent_index, PageIdT);
        if (Trait.fixed_value_size.? < required) {
            @compileError("fullaz-db Hierarchy BPT fixed_value_size cannot hold every allowed child envelope");
        }
    }
}

fn maximumAllowedChildPayloadSize(
    comptime HierarchyT: type,
    comptime parent_index: usize,
    comptime PageIdT: type,
) usize {
    var maximum: usize = 0;
    inline for (HierarchyT.types[parent_index].allowed_child_type_ids) |allowed_type_id| {
        inline for (HierarchyT.types) |entry| {
            if (entry.type_identity.type_id == allowed_type_id) {
                maximum = @max(maximum, childPayloadSize(entry.descriptor.Trait, PageIdT));
            }
        }
    }
    return maximum;
}

fn childPayloadSize(comptime Trait: type, comptime PageIdT: type) usize {
    const PackedPageId = PackedInt(PageIdT, .little);
    return switch (childKindForTrait(Trait)) {
        .bpt, .rtree, .weighted_sequence => @sizeOf(PackedPageId),
        .chain_store => 2 * @sizeOf(PackedPageId) + @sizeOf(u64),
        .slot_heap => (2 + Trait.maximum_level + 1 + Trait.size_class_count) * @sizeOf(PackedPageId) +
            @sizeOf(u16) + @sizeOf(u64),
    };
}

fn childKindForTrait(comptime Trait: type) ChildKind {
    if (@hasDecl(Trait, "fixed_value_size") and @hasDecl(Trait, "compare") and
        @hasDecl(Trait, "rebalance_policy") and @hasDecl(Trait, "CompareContext") and
        Trait.page_kind_count == 2)
    {
        return .bpt;
    }
    if (comptime std.mem.eql(u8, Trait.kind_name, "fullaz.chain-store.paged") and
        Trait.page_kind_count == 1)
    {
        return .chain_store;
    }
    if (comptime std.mem.eql(u8, Trait.kind_name, "fullaz.rtree.paged") and
        Trait.page_kind_count == 2 and
        @hasDecl(Trait, "Coord") and
        @hasDecl(Trait, "dimensions") and
        @hasDecl(Trait, "maximum_entries") and
        @hasDecl(Trait, "maximum_value_size"))
    {
        return .rtree;
    }
    if (comptime std.mem.eql(u8, Trait.kind_name, "fullaz.weighted-sequence.paged") and
        Trait.page_kind_count == 2 and
        @hasDecl(Trait, "maximum_chunk_size"))
    {
        return .weighted_sequence;
    }
    if (comptime std.mem.eql(u8, Trait.kind_name, "fullaz.slot-heap.paged") and
        Trait.page_kind_count == 3 and
        @hasDecl(Trait, "compare") and
        @hasDecl(Trait, "CompareContext") and
        @hasDecl(Trait, "comparator_id") and
        @hasDecl(Trait, "maximum_key_size") and
        @hasDecl(Trait, "maximum_value_size") and
        @hasDecl(Trait, "maximum_level") and
        @hasDecl(Trait, "SizeClassPolicy") and
        @hasDecl(Trait, "size_class_policy") and
        @hasDecl(Trait, "size_class_count"))
    {
        return .slot_heap;
    }
    @compileError("fullaz-db hierarchyStore supports BPT, ChainStore, R-tree, WeightedSequence, and SlotHeap child types only");
}

fn childPageKindCount(comptime HierarchyT: type) usize {
    var count: usize = 0;
    inline for (HierarchyT.types) |entry| {
        count += entry.descriptor.Trait.page_kind_count;
    }
    return count;
}

fn childPageKindOffset(comptime HierarchyT: type, comptime end: usize) usize {
    var offset: usize = 0;
    inline for (HierarchyT.types[0..end]) |entry| {
        offset += entry.descriptor.Trait.page_kind_count;
    }
    return offset;
}

fn buildPageRoles(comptime HierarchyT: type, comptime parent_count: usize) [parent_count + childPageKindCount(HierarchyT)][]const u8 {
    var roles: [parent_count + childPageKindCount(HierarchyT)][]const u8 = undefined;
    roles[0] = "parent_leaf";
    roles[1] = "parent_inode";
    var index = parent_count;
    inline for (HierarchyT.types) |entry| {
        inline for (entry.descriptor.Trait.page_roles) |role| {
            roles[index] = std.fmt.comptimePrint("{s}_{s}", .{ entry.tag, role });
            index += 1;
        }
    }
    return roles;
}

fn childErrors(comptime HierarchyT: type, comptime BackendT: type, comptime index: usize) type {
    if (index == HierarchyT.type_count) {
        return error{};
    }
    return HierarchyT.types[index].descriptor.Trait.Binding(BackendT).Error ||
        childErrors(HierarchyT, BackendT, index + 1);
}
