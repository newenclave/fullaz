const std = @import("std");
const fullaz = @import("fullaz");
const component = @import("../../component/component.zig");
const dynamic_metadata = @import("../../file/metadata/dynamic.zig");
const tagged = @import("../../file/tagged_fields.zig");
const hierarchy = @import("../../hierarchy.zig");
const value_envelope = @import("../../value_envelope.zig");
const embedded = @import("embedded.zig");
const PackedInt = fullaz.core.packed_int.PackedInt;
const gc = fullaz.gc;

const ChildKind = enum {
    bpt,
    chain_store,
    rtree,
    weighted_sequence,
    slot_heap,
};

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
            const ChildError = childErrors(HierarchyT, BackendT, 0);

            comptime {
                if (ParentTrait.fixed_value_size.? < value_envelope.envelope_byte_size +
                    maximumChildPayloadSize(HierarchyT, PageIdT))
                {
                    @compileError("fullaz-db hierarchyStore parent fixed_value_size cannot hold an embedded child envelope");
                }
                validateBptChildEnvelopeCapacities(HierarchyT, PageIdT);
            }

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

            const ProxyImpl = struct {
                const Self = @This();

                pub const Error = ParentBinding.Error ||
                    ChildError ||
                    value_envelope.Error ||
                    error{EditorActive};
                runtime: *RuntimeImpl,
                transaction_generation: ?u64,

                fn ChildBindingForTag(comptime tag: []const u8) type {
                    return component.bindingFor(
                        HierarchyT.entryByTag(tag).descriptor,
                        BackendT,
                    );
                }

                fn ChildStorageBindingForTag(comptime tag: []const u8) type {
                    const ChildBinding = ChildBindingForTag(tag);
                    const StorageManager = embedded.MutablePayloadStorageManager(
                        BackendT.CacheType,
                        ChildBinding.State,
                    );
                    return component.storageBindingFor(ChildBinding, BackendT, StorageManager);
                }

                pub fn emptyChildState(_: *const Self, comptime tag: []const u8) ChildBindingForTag(tag).State {
                    return ChildStorageBindingForTag(tag).emptyState();
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
                    try self.requireTransaction();
                    return embedded.EncodedValue(ParentTrait.fixed_value_size.?).formatRaw(
                        self.nextMetadata(tag),
                        payload,
                    );
                }

                pub fn encodedEmbedded(
                    self: *const Self,
                    comptime tag: []const u8,
                ) Error!embedded.EncodedValue(ParentTrait.fixed_value_size.?) {
                    try self.requireTransaction();
                    var state = emptyChildState(tag);
                    return embedded.EncodedValue(ParentTrait.fixed_value_size.?).formatEmbedded(
                        self.nextMetadata(tag),
                        std.mem.asBytes(&state),
                    );
                }

                pub fn requireTransaction(self: *const Self) Error!void {
                    if (self.transaction_generation == null or
                        self.runtime.backend.cache().transactionGeneration() != self.transaction_generation)
                    {
                        return error.TransactionInactive;
                    }
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

                        pub const Error = StorageChild.Error ||
                            Self.Error ||
                            error{ChildTypeNotAllowed};
                        pub const StorageBinding = StorageChild.StorageBinding;

                        inner: StorageChild,
                        owner: Self,

                        pub fn proxy(self: *HandleSelf) StorageChild.StorageBinding.Proxy {
                            return self.inner.proxy();
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
                            try self.owner.requireTransaction();
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
                            try self.owner.requireTransaction();
                            const parent_type_id = HierarchyT.entryByTag(parent_tag).type_identity.type_id;
                            const child_type_id = HierarchyT.entryByTag(child_tag).type_identity.type_id;
                            if (comptime !HierarchyT.allowsChild(parent_type_id, child_type_id)) {
                                return error.ChildTypeNotAllowed;
                            }
                            var state = self.owner.emptyChildState(child_tag);
                            return self.inner.formatEmbedded(
                                self.owner.nextMetadata(child_tag),
                                std.mem.asBytes(&state),
                            );
                        }

                        /// Transfers a native value editor from this child proxy
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
                        var rejected_editor = parent_editor;
                        rejected_editor.deinit();
                        return error.ChildTypeNotAllowed;
                    }
                    return .{
                        .inner = try self.openChildStorage(parent_editor, child_tag),
                        .owner = self.*,
                    };
                }
            };

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
                    // A hierarchy owns child pages referenced from envelopes.
                    // Reclaiming only the parent would orphan those pages, so
                    // reclamation stays disabled until it is recursive.
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
