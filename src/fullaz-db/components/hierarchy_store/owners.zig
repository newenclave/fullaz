const std = @import("std");
const fullaz = @import("fullaz");
const component = @import("../../component/component.zig");
const hierarchy = @import("../../hierarchy.zig");
const value_envelope = @import("../../value_envelope.zig");
const bpt_descriptor = @import("../bpt.zig");
const core = @import("bpt.zig");
const PackedInt = fullaz.core.packed_int.PackedInt;
const gc = fullaz.gc;

fn coreCompare(_: void, left: []const u8, right: []const u8) std.math.Order {
    return std.mem.order(u8, left, right);
}

fn allows(comptime HierarchyT: type, comptime allowed_ids: []const hierarchy.TypeId, comptime tag: []const u8) bool {
    const id = HierarchyT.entryByTag(tag).type_identity.type_id;
    inline for (allowed_ids) |allowed_id| {
        if (allowed_id == id) {
            return true;
        }
    }
    return false;
}

// The envelope machinery needs a BPT parent model only to own its generic
// child editors. Aggregate R-tree and SlotHeap owners never allocate through it.
fn envelopeCoreDescriptor(comptime HierarchyT: type) component.Descriptor {
    return core.hierarchyBpt(HierarchyT, bpt_descriptor.bpt(.{
        .compare = coreCompare,
        .CompareContext = void,
        .comparator_id = 0xffff_fffe,
        .maximum_key_size = 1,
        .maximum_value_size = 1024,
        .fixed_value_size = 1024,
    }));
}

pub fn bptOwner(
    comptime HierarchyT: type,
    comptime parent_descriptor: component.Descriptor,
    comptime allowed_ids: []const hierarchy.TypeId,
) component.Descriptor {
    const CoreDescriptor = core.hierarchyBpt(HierarchyT, parent_descriptor);
    const ParentTrait = parent_descriptor.Trait;
    return ownerDescriptor(HierarchyT, ParentTrait, CoreDescriptor, allowed_ids, .bpt);
}

pub fn rtreeOwner(
    comptime HierarchyT: type,
    comptime parent_descriptor: component.Descriptor,
    comptime allowed_ids: []const hierarchy.TypeId,
) component.Descriptor {
    return ownerDescriptor(HierarchyT, parent_descriptor.Trait, envelopeCoreDescriptor(HierarchyT), allowed_ids, .rtree);
}

pub fn slotHeapOwner(
    comptime HierarchyT: type,
    comptime parent_descriptor: component.Descriptor,
    comptime allowed_ids: []const hierarchy.TypeId,
) component.Descriptor {
    return ownerDescriptor(HierarchyT, parent_descriptor.Trait, envelopeCoreDescriptor(HierarchyT), allowed_ids, .slot_heap);
}

const OwnerKind = enum { bpt, rtree, slot_heap };

fn ownerDescriptor(
    comptime HierarchyT: type,
    comptime ParentTrait: type,
    comptime CoreDescriptor: component.Descriptor,
    comptime allowed_ids: []const hierarchy.TypeId,
    comptime kind: OwnerKind,
) component.Descriptor {
    const Trait = struct {
        pub const kind_name: []const u8 = switch (kind) {
            .bpt => "fullaz.hierarchy-store.bpt-owner",
            .rtree => "fullaz.hierarchy-store.rtree-owner",
            .slot_heap => "fullaz.hierarchy-store.slot-heap-owner",
        };
        pub const format_version: u32 = 1;
        pub const page_kind_count = ParentTrait.page_kind_count;
        pub const page_roles = ParentTrait.page_roles;

        pub fn fingerprint(writer: *hierarchy.FingerprintWriter) void {
            ParentTrait.fingerprint(writer);
            HierarchyT.writeFingerprint(writer);
        }

        pub fn Binding(comptime BackendT: type) type {
            const Parent = ParentTrait.Binding(BackendT);
            const Core = CoreDescriptor.Trait.Binding(BackendT);

            const ProxyImpl = struct {
                const Self = @This();
                pub const Value = Core.Proxy.EnvelopeValue;
                pub const BoundingBox = if (kind == .rtree) Parent.Proxy.BoundingBox else void;
                pub const Error = Parent.Error || Core.Error || error{TypeNotAllowed};

                parent: Parent.Proxy,
                envelope: Core.Proxy,

                pub fn raw(self: *const Self, comptime tag: []const u8, payload: []const u8) error{TypeNotAllowed}!Value {
                    if (comptime !allows(HierarchyT, allowed_ids, tag)) {
                        return error.TypeNotAllowed;
                    }
                    return self.envelope.raw(tag, payload);
                }

                pub fn embed(self: *const Self, comptime tag: []const u8) error{TypeNotAllowed}!Value {
                    if (comptime !allows(HierarchyT, allowed_ids, tag)) {
                        return error.TypeNotAllowed;
                    }
                    return self.envelope.embed(tag);
                }

                pub fn insert(self: *const Self, first: anytype, value: Value) Error!switch (kind) {
                    .bpt => bool,
                    .rtree, .slot_heap => void,
                } {
                    if (comptime kind == .bpt) {
                        return self.envelope.insert(first, value);
                    }
                    var bytes: [ParentTrait.maximum_value_size]u8 = undefined;
                    try self.envelope.formatValue(&bytes, value);
                    return switch (kind) {
                        .bpt => unreachable,
                        .rtree => self.parent.insert(first, &bytes),
                        .slot_heap => self.parent.push(first, &bytes),
                    };
                }

                pub fn push(self: *const Self, key: []const u8, value: Value) Error!void {
                    if (comptime kind != .slot_heap) {
                        @compileError("push is only available on hierarchy SlotHeap owners");
                    }
                    return self.insert(key, value);
                }

                pub fn remove(self: *const Self, key: []const u8) Error!bool {
                    if (comptime kind != .bpt) {
                        @compileError("remove is only available on hierarchy BPT owners");
                    }
                    return self.envelope.remove(key);
                }

                pub fn openEmbeddedForEdit(
                    self: *const Self,
                    first: anytype,
                    comptime tag: []const u8,
                ) Error!?Core.Proxy.EditorForTag(tag) {
                    if (comptime kind == .bpt) {
                        return self.envelope.openEmbeddedForEdit(first, tag);
                    }
                    if (comptime kind == .slot_heap) {
                        var peek = try self.parent.top();
                        defer peek.deinit();
                        var editor = try peek.editValue();
                        var transferred = false;
                        errdefer if (!transferred) {
                            editor.deinit();
                        };
                        var envelope_editor = try value_envelope.openEmbeddedMut(
                            try editor.valueMut(),
                            HierarchyT.entryByTag(tag).type_identity,
                        );
                        errdefer envelope_editor.invalidate();
                        var lease = try Core.Proxy.ValueLease.init(
                            Parent.Proxy.ValueEditor,
                            self.envelope.runtime.backend.allocator(),
                            editor,
                        );
                        transferred = true;
                        errdefer {
                            lease.rollback();
                            lease.deinit();
                        }
                        return try self.envelope.openEmbeddedForEditLease(
                            lease,
                            envelope_editor,
                            try envelope_editor.payloadMut(),
                            tag,
                        );
                    }
                    @compileError("R-tree hierarchy owner needs query, context, predicate, and type tag");
                }

                pub fn openEmbeddedHitForEdit(
                    self: *const Self,
                    query: Parent.Proxy.BoundingBox,
                    context: anytype,
                    matches: anytype,
                    comptime tag: []const u8,
                ) Error!?Core.Proxy.EditorForTag(tag) {
                    if (comptime kind != .rtree) {
                        @compileError("openEmbeddedHitForEdit is only available on hierarchy R-tree owners");
                    }
                    var editor = (try self.parent.openValueEditor(query, context, matches)) orelse return null;
                    var transferred = false;
                    errdefer if (!transferred) {
                        editor.deinit();
                    };
                    var envelope_editor = try value_envelope.openEmbeddedMut(
                        try editor.valueMut(),
                        HierarchyT.entryByTag(tag).type_identity,
                    );
                    errdefer envelope_editor.invalidate();
                    var lease = try Core.Proxy.ValueLease.init(
                        Parent.Proxy.ValueEditor,
                        self.envelope.runtime.backend.allocator(),
                        editor,
                    );
                    transferred = true;
                    errdefer {
                        lease.rollback();
                        lease.deinit();
                    }
                    return try self.envelope.openEmbeddedForEditLease(
                        lease,
                        envelope_editor,
                        try envelope_editor.payloadMut(),
                        tag,
                    );
                }

                pub fn top(self: *const Self) Error!Parent.Proxy.MutablePeek {
                    if (comptime kind != .slot_heap) {
                        @compileError("top is only available on hierarchy SlotHeap owners");
                    }
                    return self.parent.top();
                }
            };

            return struct {
                pub const Runtime = struct {
                    parent: Parent.Runtime,
                    envelope: Core.Runtime,
                    const_proxy: Parent.ConstProxy,
                };
                pub const Proxy = ProxyImpl;
                pub const ConstProxy = Parent.ConstProxy;
                pub const InitOptions = Parent.InitOptions;
                pub const TransactionState = struct { parent: Parent.TransactionState, envelope: Core.TransactionState };
                pub const Error = ProxyImpl.Error || error{InvalidPageKinds};
                pub const StaticMetadata = struct {
                    pub const Storage = extern struct {
                        parent: Parent.StaticMetadata.Storage,
                        next_instance_id: PackedInt(u64, .little),
                    };
                    pub const Error = Parent.StaticMetadata.Error || error{BadMetadata};

                    pub fn capture(runtime: *const Runtime) Storage {
                        return .{
                            .parent = if (comptime kind == .bpt)
                                Parent.StaticMetadata.capture(&runtime.envelope.parent)
                            else
                                Parent.StaticMetadata.capture(&runtime.parent),
                            .next_instance_id = PackedInt(u64, .little).init(runtime.envelope.next_instance_id),
                        };
                    }
                    pub fn restore(runtime: *Runtime, storage: *const Storage) void {
                        if (comptime kind == .bpt) {
                            Parent.StaticMetadata.restore(&runtime.envelope.parent, &storage.parent);
                        } else {
                            Parent.StaticMetadata.restore(&runtime.parent, &storage.parent);
                        }
                        runtime.envelope.next_instance_id = storage.next_instance_id.get();
                    }
                    pub fn validate(storage: *const Storage, page_count: usize) @This().Error!void {
                        try Parent.StaticMetadata.validate(&storage.parent, page_count);
                        if (storage.next_instance_id.get() == 0) return error.BadMetadata;
                    }
                };
                pub const DynamicMetadata = Parent.DynamicMetadata;

                pub fn initAggregateRuntime(runtime: *Runtime, backend: *BackendT, owner_kinds: component.PageKindRange, type_kinds: component.PageKindRange, options: InitOptions) Error!void {
                    if (owner_kinds.count != page_kind_count) return error.InvalidPageKinds;
                    if (comptime kind != .bpt) {
                        try Parent.initRuntime(&runtime.parent, backend, owner_kinds, options);
                        errdefer Parent.deinitRuntime(&runtime.parent);
                    }
                    if (comptime kind == .bpt) {
                        try Core.initAggregateRuntime(&runtime.envelope, backend, owner_kinds, type_kinds, .{});
                    } else {
                        try Core.initAggregateEnvelopeRuntime(&runtime.envelope, backend, owner_kinds, type_kinds);
                    }
                    runtime.const_proxy = if (comptime kind == .bpt)
                        Parent.proxyConst(&runtime.envelope.parent).*
                    else
                        Parent.proxyConst(&runtime.parent).*;
                }
                pub fn deinitRuntime(runtime: *Runtime) void {
                    if (comptime kind == .bpt) {
                        Core.deinitRuntime(&runtime.envelope);
                    }
                    if (comptime kind != .bpt) {
                        Parent.deinitRuntime(&runtime.parent);
                    }
                    runtime.* = undefined;
                }
                pub fn requireTransactionIdle(runtime: *const Runtime) Error!void {
                    if (comptime kind != .bpt) {
                        try Parent.requireTransactionIdle(&runtime.parent);
                    }
                    if (runtime.envelope.active_editor) {
                        return error.EditorActive;
                    }
                }
                pub fn captureTransactionState(runtime: *const Runtime) TransactionState {
                    return .{ .parent = if (comptime kind == .bpt)
                        Parent.captureTransactionState(&runtime.envelope.parent)
                    else
                        Parent.captureTransactionState(&runtime.parent), .envelope = if (comptime kind == .bpt)
                        Core.captureTransactionState(&runtime.envelope)
                    else
                        .{ .parent = undefined, .next_instance_id = runtime.envelope.next_instance_id } };
                }
                pub fn restoreTransactionState(runtime: *Runtime, state: TransactionState) void {
                    if (comptime kind == .bpt) {
                        Parent.restoreTransactionState(&runtime.envelope.parent, state.parent);
                    } else {
                        Parent.restoreTransactionState(&runtime.parent, state.parent);
                    }
                    if (comptime kind == .bpt) {
                        Core.restoreTransactionState(&runtime.envelope, state.envelope);
                    } else {
                        runtime.envelope.next_instance_id = state.envelope.next_instance_id;
                    }
                }
                pub fn proxy(runtime: *Runtime) ProxyImpl {
                    return .{ .parent = if (comptime kind == .bpt)
                        Parent.proxy(&runtime.envelope.parent)
                    else
                        Parent.proxy(&runtime.parent), .envelope = Core.proxy(&runtime.envelope) };
                }
                pub fn proxyConst(runtime: *const Runtime) *const ConstProxy {
                    return &runtime.const_proxy;
                }
                pub fn reclaimPersistent(runtime: *Runtime) Error!void {
                    try requireTransactionIdle(runtime);
                    if (comptime kind == .bpt) {
                        try Parent.reclaimPersistent(&runtime.envelope.parent);
                    } else {
                        try Parent.reclaimPersistent(&runtime.parent);
                    }
                }
                pub fn registerTypeScanners(runtime: *const Runtime, collector: anytype) @TypeOf(collector.*).Error!void {
                    try Core.registerTypeScanners(&runtime.envelope, collector);
                }
                pub fn Gc(comptime CollectorT: type) type {
                    return struct {
                        pub const RootsError = std.mem.Allocator.Error;
                        pub const RegisterError = CollectorT.Error;
                        pub fn appendRoots(runtime: *const Runtime, allocator: std.mem.Allocator, roots: *std.ArrayList(CollectorT.PageId)) RootsError!void {
                            if (comptime kind == .bpt) {
                                return Parent.Gc(CollectorT).appendRoots(&runtime.envelope.parent, allocator, roots);
                            }
                            return Parent.Gc(CollectorT).appendRoots(&runtime.parent, allocator, roots);
                        }
                        pub fn registerScanners(runtime: *const Runtime, collector: *CollectorT) RegisterError!void {
                            const kinds = if (comptime kind == .bpt) runtime.envelope.parent.page_kinds else runtime.parent.page_kinds;
                            if (comptime kind == .bpt) {
                                try collector.registerForCycle(kinds.kindAt(0).?, 1, &runtime.envelope.parent.tree, gc.scanners.method(CollectorT, Parent.Tree, Parent.Tree.scanLeafRefs), Core.hierarchyValueScanner(CollectorT));
                                try collector.registerForCycle(kinds.kindAt(1).?, 1, &runtime.envelope.parent.tree, gc.scanners.method(CollectorT, Parent.Tree, Parent.Tree.scanInodeRefs), null);
                            } else if (comptime kind == .rtree) {
                                try collector.registerForCycle(kinds.kindAt(0).?, 1, &runtime.parent.tree, gc.scanners.method(CollectorT, Parent.Tree, Parent.Tree.scanLeafRefs), Core.hierarchyValueScanner(CollectorT));
                                try collector.registerForCycle(kinds.kindAt(1).?, 1, &runtime.parent.tree, gc.scanners.method(CollectorT, Parent.Tree, Parent.Tree.scanInodeRefs), null);
                            } else {
                                try collector.registerForCycle(kinds.kindAt(0).?, 1, &runtime.parent.heap, gc.scanners.method(CollectorT, Parent.Heap, Parent.Heap.scanLeafRefs), Core.hierarchyValueScanner(CollectorT));
                                try collector.registerForCycle(kinds.kindAt(1).?, 1, &runtime.parent.heap, gc.scanners.method(CollectorT, Parent.Heap, Parent.Heap.scanInodeRefs), null);
                                try collector.registerForCycle(kinds.kindAt(2).?, 1, &runtime.parent.fsm, gc.scanners.method(CollectorT, @TypeOf(runtime.parent.fsm), @TypeOf(runtime.parent.fsm).scanSlabRefs), null);
                            }
                        }
                    };
                }
            };
        }
    };
    return component.descriptor(Trait);
}
