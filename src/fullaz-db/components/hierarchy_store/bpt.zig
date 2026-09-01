const std = @import("std");
const fullaz = @import("fullaz");
const component = @import("../../component/component.zig");
const dynamic_metadata = @import("../../file/metadata/dynamic.zig");
const tagged = @import("../../file/tagged_fields.zig");
const hierarchy = @import("../../hierarchy.zig");
const value_envelope = @import("../../value_envelope.zig");
const PackedInt = fullaz.core.packed_int.PackedInt;
const low_level_bpt = fullaz.bpt;
const low_level_rtree = fullaz.spatial.rtree;
const weighted_bpt = fullaz.weighted_bpt;
const weighted_seq = fullaz.storage.weighted_seq;
const slot_heap_page = fullaz.page.slot_heap;
const fsm = fullaz.storage.fsm;
const low_level_slot_heap = fullaz.storage.slot_heap;
const gc = fullaz.gc;

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

/// Releases the parent editor's child-active state without exposing its owner.
pub const ChildActiveLease = struct {
    context: *anyopaque,
    release_fn: *const fn (*anyopaque) void,

    pub fn release(self: *const @This()) void {
        self.release_fn(self.context);
    }
};

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
pub fn hierarchyBpt(
    comptime HierarchyT: type,
    comptime parent_descriptor: component.Descriptor,
) component.Descriptor {
    comptime validate(HierarchyT, parent_descriptor);
    const ParentTrait = parent_descriptor.Trait;
    const hierarchy_page_kind_count = ParentTrait.page_kind_count + childPageKindCount(HierarchyT);
    const hierarchy_page_roles = comptime buildPageRoles(HierarchyT, ParentTrait.page_kind_count);

    const Trait = struct {
        pub const kind_name: []const u8 = "fullaz.bpt.embedded-hierarchy";
        pub const format_version: u32 = 1;
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
            const PackedSize = PackedInt(u64, .little);
            const ChildError = childErrors(HierarchyT, BackendT, 0);

            comptime {
                if (ParentTrait.fixed_value_size.? < value_envelope.envelope_byte_size +
                    maximumChildPayloadSize(HierarchyT, PageIdT))
                {
                    @compileError("fullaz-db hierarchyBpt parent fixed_value_size cannot hold an embedded child envelope");
                }
                validateBptChildEnvelopeCapacities(HierarchyT, PageIdT);
            }

            const InlineRootManager = struct {
                pub const Error = CacheT.Error;
                pub const PageId = CacheT.Pid;

                cache: *CacheT,
                root: *PackedRoot,

                fn init(cache: *CacheT, root: *PackedRoot) @This() {
                    return .{ .cache = cache, .root = root };
                }

                pub fn getRoot(self: *const @This()) ?PageIdT {
                    const root = self.root.get();
                    return if (root == 0) null else root;
                }

                pub fn setRoot(self: *@This(), root: ?PageIdT) Error!void {
                    self.root.set(root orelse 0);
                }

                pub fn destroyPage(self: *@This(), page_id: PageIdT) Error!void {
                    return self.cache.free(page_id);
                }
            };

            const ConstInlineRootManager = struct {
                pub const Error = error{ReadOnly};
                pub const PageId = PageIdT;

                root: *const PackedRoot,

                fn init(root: *const PackedRoot) @This() {
                    return .{ .root = root };
                }

                pub fn getRoot(self: *const @This()) ?PageIdT {
                    const root = self.root.get();
                    return if (root == 0) null else root;
                }

                pub fn setRoot(_: *@This(), _: ?PageIdT) Error!void {
                    return error.ReadOnly;
                }

                pub fn destroyPage(_: *@This(), _: PageIdT) Error!void {
                    return error.ReadOnly;
                }
            };

            const InlineChainStorePayload = extern struct {
                first: PackedRoot,
                last: PackedRoot,
                total_size: PackedSize,
            };

            comptime {
                if (@alignOf(InlineChainStorePayload) != 1 or
                    @sizeOf(InlineChainStorePayload) != 2 * @sizeOf(PackedRoot) + @sizeOf(PackedSize) or
                    @offsetOf(InlineChainStorePayload, "first") != 0 or
                    @offsetOf(InlineChainStorePayload, "last") != @sizeOf(PackedRoot) or
                    @offsetOf(InlineChainStorePayload, "total_size") != 2 * @sizeOf(PackedRoot))
                {
                    @compileError("inline ChainStore payload layout changed");
                }
            }

            const InlineChainStoreManager = struct {
                const Self = @This();

                pub const Error = CacheT.Error;
                pub const PageId = PageIdT;
                pub const Size = u64;

                cache: *CacheT,
                payload: *InlineChainStorePayload,

                fn init(cache: *CacheT, payload: *InlineChainStorePayload) Self {
                    return .{ .cache = cache, .payload = payload };
                }

                pub fn getTotalSize(self: *const Self) Error!Size {
                    return self.payload.total_size.get();
                }

                pub fn setTotalSize(self: *Self, total_size: Size) Error!void {
                    self.payload.total_size.set(total_size);
                }

                pub fn getFirst(self: *const Self) Error!?PageId {
                    const first = self.payload.first.get();
                    return if (first == 0) null else first;
                }

                pub fn setFirst(self: *Self, first: ?PageId) Error!void {
                    self.payload.first.set(first orelse 0);
                }

                pub fn getLast(self: *const Self) Error!?PageId {
                    const last = self.payload.last.get();
                    return if (last == 0) null else last;
                }

                pub fn setLast(self: *Self, last: ?PageId) Error!void {
                    self.payload.last.set(last orelse 0);
                }

                pub fn destroyPage(self: *Self, page_id: PageId) Error!void {
                    return self.cache.free(page_id);
                }
            };

            const SlotHeapChildFactory = struct {
                pub fn get(comptime index: usize) type {
                    const ChildTrait = HierarchyT.types[index].descriptor.Trait;
                    const Format = slot_heap_page.SlotHeap(PageIdT, u16, .little);
                    const LocationAccessor = slot_heap_page.LeafPageLocationAccessor(PageIdT, u16, .little);
                    const PackedSlot = PackedInt(u16, .little);
                    const PackedLocation = extern struct {
                        page_id: PackedRoot,
                        slot_id: PackedSlot,
                    };
                    const Payload = extern struct {
                        root: PackedRoot,
                        cached_top: PackedLocation,
                        entries_count: PackedSize,
                        available_inode_heads: [ChildTrait.maximum_level + 1]PackedRoot,
                        fsm_class_roots: [ChildTrait.size_class_count]PackedRoot,
                    };

                    comptime {
                        if (@alignOf(PackedLocation) != 1 or
                            @sizeOf(PackedLocation) != @sizeOf(PackedRoot) + @sizeOf(PackedSlot) or
                            @alignOf(Payload) != 1 or
                            @sizeOf(Payload) != 2 * @sizeOf(PackedRoot) + @sizeOf(PackedSlot) + @sizeOf(PackedSize) +
                                (ChildTrait.maximum_level + 1 + ChildTrait.size_class_count) * @sizeOf(PackedRoot) or
                            @offsetOf(Payload, "root") != 0 or
                            @offsetOf(Payload, "cached_top") != @sizeOf(PackedRoot) or
                            @offsetOf(Payload, "entries_count") != @sizeOf(PackedRoot) + @sizeOf(PackedLocation))
                        {
                            @compileError("inline SlotHeap payload layout changed");
                        }
                    }

                    const InlineManager = struct {
                        const Self = @This();

                        pub const PageId = PageIdT;
                        pub const CountType = u64;
                        pub const Error = CacheT.Error || error{
                            InvalidSizeClass,
                            MaxDepth,
                        };

                        cache: *CacheT,
                        payload: *Payload,

                        pub fn init(cache: *CacheT, payload: *Payload) Self {
                            return .{ .cache = cache, .payload = payload };
                        }

                        pub fn getRoot(self: *const Self) ?PageId {
                            const root = self.payload.root.get();
                            return if (root == 0) null else root;
                        }

                        pub fn setRoot(self: *Self, root: ?PageId) Error!void {
                            self.payload.root.set(root orelse 0);
                        }

                        pub fn getCachedTop(self: *const Self) ?Format.Location {
                            const page_is_null = self.payload.cached_top.page_id.isMax();
                            const slot_is_null = self.payload.cached_top.slot_id.isMax();
                            if (page_is_null or slot_is_null) {
                                return null;
                            }
                            return .{
                                .page_id = self.payload.cached_top.page_id.get(),
                                .slot_id = self.payload.cached_top.slot_id.get(),
                            };
                        }

                        pub fn setCachedTop(self: *Self, top: ?Format.Location) Error!void {
                            if (top) |location| {
                                self.payload.cached_top.page_id.set(location.page_id);
                                self.payload.cached_top.slot_id.set(location.slot_id);
                            } else {
                                self.payload.cached_top.page_id.setMax();
                                self.payload.cached_top.slot_id.setMax();
                            }
                        }

                        pub fn getEntriesCount(self: *const Self) Error!CountType {
                            return self.payload.entries_count.get();
                        }

                        pub fn setEntriesCount(self: *Self, count: CountType) Error!void {
                            self.payload.entries_count.set(count);
                        }

                        pub fn getAvailableInode(self: *const Self, level: usize) Error!?PageId {
                            if (level == 0 or level > ChildTrait.maximum_level) {
                                return Error.MaxDepth;
                            }
                            const page_id = self.payload.available_inode_heads[level].get();
                            return if (page_id == 0) null else page_id;
                        }

                        pub fn setAvailableInode(self: *Self, level: usize, inode: ?PageId) Error!void {
                            if (level == 0 or level > ChildTrait.maximum_level) {
                                return Error.MaxDepth;
                            }
                            self.payload.available_inode_heads[level].set(inode orelse 0);
                        }

                        pub fn getSizeClassRoot(self: *const Self, class: u16) Error!?PageId {
                            const index_: usize = class;
                            if (index_ >= ChildTrait.size_class_count) {
                                return Error.InvalidSizeClass;
                            }
                            const page_id = self.payload.fsm_class_roots[index_].get();
                            return if (page_id == 0) null else page_id;
                        }

                        pub fn setSizeClassRoot(self: *Self, class: u16, root: ?PageId) Error!void {
                            const index_: usize = class;
                            if (index_ >= ChildTrait.size_class_count) {
                                return Error.InvalidSizeClass;
                            }
                            self.payload.fsm_class_roots[index_].set(root orelse 0);
                        }

                        pub fn destroyPage(self: *Self, page_id: PageId) Error!void {
                            return self.cache.free(page_id);
                        }
                    };
                    const FsmModel = fsm.models.paged.slab.Model(
                        CacheT,
                        InlineManager,
                        ChildTrait.SizeClassPolicy,
                        LocationAccessor,
                    );
                    const Fsm = fsm.Fsm(FsmModel);
                    const Model = low_level_slot_heap.models.Paged(
                        CacheT,
                        InlineManager,
                        Fsm,
                        ChildTrait.compare,
                        ChildTrait.CompareContext,
                    );
                    const Heap = low_level_slot_heap.Heap(Model);

                    return struct {
                        pub const PayloadType = Payload;
                        pub const Manager = InlineManager;
                        pub const FsmModelType = FsmModel;
                        pub const FsmType = Fsm;
                        pub const ModelType = Model;
                        pub const HeapType = Heap;

                        pub fn emptyPayload() Payload {
                            var payload: Payload = undefined;
                            payload.root = PackedRoot.init(0);
                            payload.cached_top.page_id.setMax();
                            payload.cached_top.slot_id.setMax();
                            payload.entries_count = PackedSize.init(0);
                            inline for (&payload.available_inode_heads) |*head| {
                                head.* = PackedRoot.init(0);
                            }
                            inline for (&payload.fsm_class_roots) |*root| {
                                root.* = PackedRoot.init(0);
                            }
                            return payload;
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
                    ConstInlineRootManager.Error ||
                    std.mem.Allocator.Error;
                pub const Iterator = ParentBinding.ConstProxy.Iterator;
                pub const ConstIterator = Iterator;

                runtime: *const ConstRuntime,

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

                /// A read-only BPT facade that pins its parent embedded value.
                /// Deinitialize all iterators before this reader.
                pub fn EmbeddedBptReader(comptime tag: []const u8) type {
                    if (comptime childKind(HierarchyT, HierarchyT.indexOfTag(tag)) != .bpt) {
                        @compileError("openEmbeddedBpt requires a registered BPT child type");
                    }
                    const ChildTrait = HierarchyT.entryByTag(tag).descriptor.Trait;
                    const ChildModel = low_level_bpt.models.PagedModel(
                        CacheT,
                        ConstInlineRootManager,
                        ChildTrait.compare,
                        ChildTrait.CompareContext,
                    );
                    const ChildTree = low_level_bpt.Bpt(ChildModel);

                    return struct {
                        const ReaderSelf = @This();

                        const State = struct {
                            manager: ConstInlineRootManager,
                            model: ChildModel,
                            tree: ChildTree,
                        };

                        pub const Error = ChildTree.Error ||
                            value_envelope.Error ||
                            std.mem.Allocator.Error;
                        pub const Iterator = struct {
                            const IteratorSelf = @This();

                            inner: ChildTree.Iterator,

                            pub fn get(self: *const IteratorSelf) @TypeOf(self.inner.get()) {
                                return self.inner.get();
                            }

                            pub fn next(self: *IteratorSelf) @TypeOf(self.inner.next()) {
                                return self.inner.next();
                            }

                            pub fn prev(self: *IteratorSelf) @TypeOf(self.inner.prev()) {
                                return self.inner.prev();
                            }

                            pub fn deinit(self: *IteratorSelf) void {
                                self.inner.deinit();
                                self.* = undefined;
                            }
                        };

                        parent_iterator: ParentBinding.ConstProxy.Iterator,
                        state: *State,
                        allocator: std.mem.Allocator,

                        fn init(
                            allocator: std.mem.Allocator,
                            cache: *CacheT,
                            page_kinds: component.PageKindRange,
                            payload: []const u8,
                            parent_iterator: ParentBinding.ConstProxy.Iterator,
                        ) ReaderSelf.Error!ReaderSelf {
                            if (payload.len != @sizeOf(PackedRoot)) {
                                return error.BadPayloadLength;
                            }
                            const root: *const PackedRoot = @ptrCast(payload.ptr);
                            const state = try allocator.create(State);
                            errdefer allocator.destroy(state);
                            state.manager = ConstInlineRootManager.init(root);
                            state.model = try ChildModel.init(
                                cache,
                                &state.manager,
                                .{
                                    .maximum_key_size = ChildTrait.maximum_key_size,
                                    .maximum_value_size = ChildTrait.maximum_value_size,
                                    .fixed_value_size = ChildTrait.fixed_value_size,
                                    .leaf_page_kind = page_kinds.kindAt(0).?,
                                    .inode_page_kind = page_kinds.kindAt(1).?,
                                },
                                {},
                            );
                            errdefer state.model.deinit();
                            state.tree = .init(&state.model, ChildTrait.rebalance_policy);
                            return .{
                                .parent_iterator = parent_iterator,
                                .state = state,
                                .allocator = allocator,
                            };
                        }

                        pub fn iterator(self: *const ReaderSelf) ReaderSelf.Error!?ReaderSelf.Iterator {
                            if (try self.state.tree.iterator()) |inner| {
                                return .{ .inner = inner };
                            }
                            return null;
                        }

                        pub fn iteratorFromEnd(self: *const ReaderSelf) ReaderSelf.Error!?ReaderSelf.Iterator {
                            if (try self.state.tree.iteratorFromEnd()) |inner| {
                                return .{ .inner = inner };
                            }
                            return null;
                        }

                        pub fn find(
                            self: *const ReaderSelf,
                            key: []const u8,
                        ) ReaderSelf.Error!?ReaderSelf.Iterator {
                            if (try self.state.tree.find(key)) |inner| {
                                return .{ .inner = inner };
                            }
                            return null;
                        }

                        pub fn lowerBound(
                            self: *const ReaderSelf,
                            key: []const u8,
                        ) ReaderSelf.Error!?ReaderSelf.Iterator {
                            if (try self.state.tree.lowerBound(key)) |inner| {
                                return .{ .inner = inner };
                            }
                            return null;
                        }

                        pub fn deinit(self: *ReaderSelf) void {
                            self.state.tree.deinit();
                            self.state.model.deinit();
                            self.allocator.destroy(self.state);
                            self.parent_iterator.deinit();
                            self.* = undefined;
                        }
                    };
                }

                /// Opens an exact embedded BPT and retains its parent value pin.
                pub fn openEmbeddedBpt(
                    self: *const Self,
                    key: []const u8,
                    comptime tag: []const u8,
                ) Error!?EmbeddedBptReader(tag) {
                    const Reader = EmbeddedBptReader(tag);
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
                    const reader = try Reader.init(
                        self.runtime.backend.allocator(),
                        self.runtime.backend.cache(),
                        self.runtime.childPageKinds(HierarchyT.indexOfTag(tag)),
                        value.payload,
                        parent_iterator,
                    );
                    transferred = true;
                    return reader;
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
                    const instance_id = self.next_instance_id;
                    self.next_instance_id = std.math.add(u64, instance_id, 1) catch
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
                    const ChildTrait = HierarchyT.types[index].descriptor.Trait;
                    const ChildModel = low_level_bpt.models.PagedModel(
                        CacheT,
                        InlineRootManager,
                        ChildTrait.compare,
                        ChildTrait.CompareContext,
                    );
                    var root = PackedRoot.init(0);
                    var manager = InlineRootManager.init(self.backend.cache(), &root);
                    var model = try ChildModel.init(
                        self.backend.cache(),
                        &manager,
                        .{
                            .maximum_key_size = ChildTrait.maximum_key_size,
                            .maximum_value_size = ChildTrait.maximum_value_size,
                            .fixed_value_size = ChildTrait.fixed_value_size,
                            .leaf_page_kind = self.childPageKinds(index).kindAt(0).?,
                            .inode_page_kind = self.childPageKinds(index).kindAt(1).?,
                        },
                        {},
                    );
                    defer model.deinit();
                    return model.scanLeafRefs(page_id, page, visitor);
                }

                fn scanWeightedSequenceChildLeaf(
                    self: *const @This(),
                    comptime index: usize,
                    page_id: PageIdT,
                    page: []const u8,
                    visitor: anytype,
                ) !void {
                    const ChildTrait = HierarchyT.types[index].descriptor.Trait;
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
                    var root = PackedRoot.init(0);
                    var manager = InlineRootManager.init(self.backend.cache(), &root);
                    var model = ChildModel.init(
                        self.backend.cache(),
                        &manager,
                        .{
                            .maximum_value_size = ChildTrait.maximum_chunk_size,
                            .leaf_page_kind = self.childPageKinds(index).kindAt(0).?,
                            .inode_page_kind = self.childPageKinds(index).kindAt(1).?,
                        },
                    );
                    defer model.deinit();
                    var tree = ChildTree.init(&model, .neighbor_share);
                    defer tree.deinit();
                    var sequence = Sequence.init(&tree);
                    return sequence.scanLeafRefs(page_id, page, visitor);
                }

                fn scanWeightedSequenceChildInode(
                    self: *const @This(),
                    comptime index: usize,
                    page_id: PageIdT,
                    page: []const u8,
                    visitor: anytype,
                ) !void {
                    const ChildTrait = HierarchyT.types[index].descriptor.Trait;
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
                    var root = PackedRoot.init(0);
                    var manager = InlineRootManager.init(self.backend.cache(), &root);
                    var model = ChildModel.init(
                        self.backend.cache(),
                        &manager,
                        .{
                            .maximum_value_size = ChildTrait.maximum_chunk_size,
                            .leaf_page_kind = self.childPageKinds(index).kindAt(0).?,
                            .inode_page_kind = self.childPageKinds(index).kindAt(1).?,
                        },
                    );
                    defer model.deinit();
                    var tree = ChildTree.init(&model, .neighbor_share);
                    defer tree.deinit();
                    var sequence = Sequence.init(&tree);
                    return sequence.scanInodeRefs(page_id, page, visitor);
                }

                fn scanChainStoreChild(
                    self: *const @This(),
                    comptime index: usize,
                    page_id: PageIdT,
                    page: []const u8,
                    visitor: anytype,
                ) !void {
                    const ChainBlob = fullaz.storage.chain_store.Blob(
                        CacheT,
                        InlineChainStoreManager,
                        .little,
                    );
                    var payload: InlineChainStorePayload = undefined;
                    var manager = InlineChainStoreManager.init(self.backend.cache(), &payload);
                    var blob = ChainBlob.init(
                        self.backend.cache(),
                        &manager,
                        .{ .chunk_page_kind = self.childPageKinds(index).kindAt(0).? },
                    );
                    defer blob.deinit();
                    return blob.scanChunkRefs(page_id, page, visitor);
                }

                fn scanRtreeChildLeaf(
                    self: *const @This(),
                    comptime index: usize,
                    page_id: PageIdT,
                    page: []const u8,
                    visitor: anytype,
                ) !void {
                    const ChildTrait = HierarchyT.types[index].descriptor.Trait;
                    const ChildModel = low_level_rtree.models.Paged(
                        CacheT,
                        InlineRootManager,
                        ChildTrait.Coord,
                        ChildTrait.dimensions,
                        ChildTrait.maximum_entries,
                        ChildTrait.maximum_value_size,
                        .little,
                    );
                    var root = PackedRoot.init(0);
                    var manager = InlineRootManager.init(self.backend.cache(), &root);
                    var model = try ChildModel.init(
                        self.backend.cache(),
                        &manager,
                        .{
                            .leaf_page_kind = self.childPageKinds(index).kindAt(0).?,
                            .inode_page_kind = self.childPageKinds(index).kindAt(1).?,
                        },
                    );
                    defer model.deinit();
                    return model.scanLeafRefs(page_id, page, visitor);
                }

                fn scanRtreeChildInode(
                    self: *const @This(),
                    comptime index: usize,
                    page_id: PageIdT,
                    page: []const u8,
                    visitor: anytype,
                ) !void {
                    const ChildTrait = HierarchyT.types[index].descriptor.Trait;
                    const ChildModel = low_level_rtree.models.Paged(
                        CacheT,
                        InlineRootManager,
                        ChildTrait.Coord,
                        ChildTrait.dimensions,
                        ChildTrait.maximum_entries,
                        ChildTrait.maximum_value_size,
                        .little,
                    );
                    var root = PackedRoot.init(0);
                    var manager = InlineRootManager.init(self.backend.cache(), &root);
                    var model = try ChildModel.init(
                        self.backend.cache(),
                        &manager,
                        .{
                            .leaf_page_kind = self.childPageKinds(index).kindAt(0).?,
                            .inode_page_kind = self.childPageKinds(index).kindAt(1).?,
                        },
                    );
                    defer model.deinit();
                    return model.scanInodeRefs(page_id, page, visitor);
                }

                fn scanSlotHeapChildLeaf(
                    self: *const @This(),
                    comptime index: usize,
                    page_id: PageIdT,
                    page: []const u8,
                    visitor: anytype,
                ) !void {
                    const Child = SlotHeapChildFactory.get(index);
                    var payload = Child.emptyPayload();
                    var manager = Child.Manager.init(self.backend.cache(), &payload);
                    var fsm_model = Child.FsmModelType.init(
                        self.backend.cache(),
                        &manager,
                        HierarchyT.types[index].descriptor.Trait.size_class_policy,
                        .{ .page_kind = self.childPageKinds(index).kindAt(2).? },
                    );
                    defer fsm_model.deinit();
                    var fsm_value = Child.FsmType.init(&fsm_model);
                    defer fsm_value.deinit();
                    var model = try Child.ModelType.init(
                        self.backend.cache(),
                        &manager,
                        &fsm_value,
                        .{
                            .key_size = HierarchyT.types[index].descriptor.Trait.maximum_key_size,
                            .maximum_value_size = HierarchyT.types[index].descriptor.Trait.maximum_value_size,
                            .comparator_id = HierarchyT.types[index].descriptor.Trait.comparator_id,
                            .leaf_page_kind = self.childPageKinds(index).kindAt(0).?,
                            .inode_page_kind = self.childPageKinds(index).kindAt(1).?,
                            .maximum_level = HierarchyT.types[index].descriptor.Trait.maximum_level,
                        },
                        {},
                    );
                    defer model.deinit();
                    var heap = Child.HeapType.init(&model);
                    return heap.scanLeafRefs(page_id, page, visitor);
                }

                fn scanSlotHeapChildInode(
                    self: *const @This(),
                    comptime index: usize,
                    page_id: PageIdT,
                    page: []const u8,
                    visitor: anytype,
                ) !void {
                    const Child = SlotHeapChildFactory.get(index);
                    var payload = Child.emptyPayload();
                    var manager = Child.Manager.init(self.backend.cache(), &payload);
                    var fsm_model = Child.FsmModelType.init(
                        self.backend.cache(),
                        &manager,
                        HierarchyT.types[index].descriptor.Trait.size_class_policy,
                        .{ .page_kind = self.childPageKinds(index).kindAt(2).? },
                    );
                    defer fsm_model.deinit();
                    var fsm_value = Child.FsmType.init(&fsm_model);
                    defer fsm_value.deinit();
                    var model = try Child.ModelType.init(
                        self.backend.cache(),
                        &manager,
                        &fsm_value,
                        .{
                            .key_size = HierarchyT.types[index].descriptor.Trait.maximum_key_size,
                            .maximum_value_size = HierarchyT.types[index].descriptor.Trait.maximum_value_size,
                            .comparator_id = HierarchyT.types[index].descriptor.Trait.comparator_id,
                            .leaf_page_kind = self.childPageKinds(index).kindAt(0).?,
                            .inode_page_kind = self.childPageKinds(index).kindAt(1).?,
                            .maximum_level = HierarchyT.types[index].descriptor.Trait.maximum_level,
                        },
                        {},
                    );
                    defer model.deinit();
                    var heap = Child.HeapType.init(&model);
                    return heap.scanInodeRefs(page_id, page, visitor);
                }

                fn scanSlotHeapChildFsmSlab(
                    self: *const @This(),
                    comptime index: usize,
                    page_id: PageIdT,
                    page: []const u8,
                    visitor: anytype,
                ) !void {
                    const Child = SlotHeapChildFactory.get(index);
                    var payload = Child.emptyPayload();
                    var manager = Child.Manager.init(self.backend.cache(), &payload);
                    var fsm_model = Child.FsmModelType.init(
                        self.backend.cache(),
                        &manager,
                        HierarchyT.types[index].descriptor.Trait.size_class_policy,
                        .{ .page_kind = self.childPageKinds(index).kindAt(2).? },
                    );
                    defer fsm_model.deinit();
                    var fsm_value = Child.FsmType.init(&fsm_model);
                    defer fsm_value.deinit();
                    return fsm_value.scanSlabRefs(page_id, page, visitor);
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
                                    if (comptime childKind(HierarchyT, index) == .slot_heap) {
                                        const Child = SlotHeapChildFactory.get(index);
                                        if (value.payload.len != @sizeOf(Child.PayloadType)) {
                                            return error.InvalidPage;
                                        }
                                        const payload: *const Child.PayloadType = @ptrCast(value.payload.ptr);
                                        const root = payload.root.get();
                                        if (root != 0) {
                                            try sink.visit(root);
                                        }
                                        for (payload.fsm_class_roots) |fsm_root| {
                                            const page_id = fsm_root.get();
                                            if (page_id != 0) {
                                                try sink.visit(page_id);
                                            }
                                        }
                                    } else switch (childKind(HierarchyT, index)) {
                                        .bpt, .rtree, .weighted_sequence => {
                                            if (value.payload.len != @sizeOf(PackedRoot)) {
                                                return error.InvalidPage;
                                            }
                                            const root: *const PackedRoot = @ptrCast(value.payload.ptr);
                                            if (root.get() != 0) {
                                                try sink.visit(root.get());
                                            }
                                        },
                                        .chain_store => {
                                            if (value.payload.len != @sizeOf(InlineChainStorePayload)) {
                                                return error.InvalidPage;
                                            }
                                            const payload: *const InlineChainStorePayload = @ptrCast(value.payload.ptr);
                                            const first = payload.first.get();
                                            if (first != 0) {
                                                try sink.visit(first);
                                            }
                                        },
                                        .slot_heap => unreachable,
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
                            const ChildTrait = HierarchyT.types[index].descriptor.Trait;
                            const ChildModel = low_level_bpt.models.PagedModel(
                                CacheT,
                                InlineRootManager,
                                ChildTrait.compare,
                                ChildTrait.CompareContext,
                            );
                            var root = PackedRoot.init(0);
                            var manager = InlineRootManager.init(runtime.backend.cache(), &root);
                            var model = ChildModel.init(
                                runtime.backend.cache(),
                                &manager,
                                .{
                                    .maximum_key_size = ChildTrait.maximum_key_size,
                                    .maximum_value_size = ChildTrait.maximum_value_size,
                                    .fixed_value_size = ChildTrait.fixed_value_size,
                                    .leaf_page_kind = runtime.childPageKinds(index).kindAt(0).?,
                                    .inode_page_kind = runtime.childPageKinds(index).kindAt(1).?,
                                },
                                {},
                            ) catch return error.InvalidPage;
                            defer model.deinit();
                            var visitor = SinkVisitor(CollectorT){ .sink = sink };
                            model.scanInodeRefs(page_id, page, &visitor) catch |err| {
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
                                return self.manager.getRoot();
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
                                return self.manager.getFirst();
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
                                return self.manager.getRoot();
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
                                return self.manager.getRoot();
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
                            manager: *Child.Manager,
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
                            pub fn root(self: *const Self) ?PageIdT {
                                return self.manager.getRoot();
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

                const ProxyImpl = struct {
                    const Self = @This();
                    pub const Error = ParentBinding.Error || ChildError || value_envelope.Error || error{EditorActive};
                    pub const EnvelopeValue = Value;
                    pub const ValueLease = ValueEditorOwner;

                    runtime: *RuntimeImpl,
                    transaction_generation: ?u64,

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
                        if (payload.len != @sizeOf(InlineChainStorePayload)) {
                            return error.BadPayloadLength;
                        }
                        const chain_payload: *InlineChainStorePayload = @ptrCast(payload.ptr);
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
                        const manager = try self.runtime.backend.allocator().create(Child.Manager);
                        errdefer self.runtime.backend.allocator().destroy(manager);
                        manager.* = Child.Manager.init(self.runtime.backend.cache(), storage);
                        const fsm_model = try self.runtime.backend.allocator().create(Child.FsmModelType);
                        errdefer self.runtime.backend.allocator().destroy(fsm_model);
                        fsm_model.* = Child.FsmModelType.init(
                            self.runtime.backend.cache(),
                            manager,
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
                            manager,
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
                            .manager = manager,
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
                                var root = PackedRoot.init(0);
                                var chain_payload = InlineChainStorePayload{
                                    .first = PackedRoot.init(0),
                                    .last = PackedRoot.init(0),
                                    .total_size = PackedSize.init(0),
                                };
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
                }

                pub fn deinitRuntime(runtime: *RuntimeImpl) void {
                    requireTransactionIdle(runtime) catch
                        @panic("hierarchyBpt runtime deinitialized with an active value editor");
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
                            if (runtime.parent.manager.getRoot()) |root| {
                                try roots.append(allocator, root);
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
        @compileError("fullaz-db hierarchyBpt requires a fullaz-db Hierarchy type");
    }
    if (!@hasDecl(parent_descriptor.Trait, "fixed_value_size") or parent_descriptor.Trait.fixed_value_size == null) {
        @compileError("fullaz-db hierarchyBpt parent BPT requires fixed_value_size");
    }
    if (parent_descriptor.Trait.fixed_value_size.? < value_envelope.envelope_byte_size + 1) {
        @compileError("fullaz-db hierarchyBpt parent fixed_value_size cannot hold an embedded child envelope");
    }
    inline for (HierarchyT.types) |entry| {
        const Trait = entry.descriptor.Trait;
        switch (childKindForTrait(Trait)) {
            .bpt => {
                if (Trait.CompareContext != void) {
                    @compileError("fullaz-db hierarchyBpt currently requires void BPT child compare contexts");
                }
            },
            .chain_store => {},
            .rtree => {},
            .weighted_sequence => {
                if (@TypeOf(Trait.maximum_chunk_size) != usize) {
                    @compileError("fullaz-db hierarchyBpt weightedSequence child maximum_chunk_size must be usize");
                }
                if (Trait.maximum_chunk_size == 0) {
                    @compileError("fullaz-db hierarchyBpt weightedSequence child maximum_chunk_size must be non-zero");
                }
            },
            .slot_heap => {
                if (Trait.CompareContext != void) {
                    @compileError("fullaz-db hierarchyBpt currently requires void SlotHeap child compare contexts");
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
    @compileError("fullaz-db hierarchyBpt supports BPT, ChainStore, R-tree, WeightedSequence, and SlotHeap child types only");
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

fn indexForIdentity(comptime HierarchyT: type, metadata: value_envelope.Metadata) ?usize {
    inline for (HierarchyT.types, 0..) |entry, index| {
        const identity = entry.type_identity;
        if (metadata.registry_id == identity.registry_id and
            metadata.type_id == identity.type_id and
            metadata.type_version == identity.type_version and
            metadata.metadata_format_version == identity.metadata_format_version)
        {
            return index;
        }
    }
    return null;
}
