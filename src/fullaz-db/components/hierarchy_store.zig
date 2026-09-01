const std = @import("std");
const component = @import("../component/component.zig");
const hierarchy = @import("../hierarchy.zig");
const dynamic_metadata = @import("../file/metadata/dynamic.zig");
const tagged = @import("../file/tagged_fields.zig");
const hierarchy_bpt = @import("hierarchy_store/bpt.zig");
const hierarchy_owners = @import("hierarchy_store/owners.zig");

/// A hierarchy aggregate owns all top-level structural ranges followed by one
/// shared block for every nominal hierarchy type.
pub fn hierarchyStore(comptime HierarchyT: type, comptime options: hierarchy.StoreOptions) component.Descriptor {
    @setEvalBranchQuota(100_000);
    comptime validate(HierarchyT, options);
    const owner_page_kinds = ownerPageKindCount(HierarchyT, options);
    const total_page_kinds = owner_page_kinds + typePageKindCount(HierarchyT, options);

    const Trait = struct {
        pub const kind_name: []const u8 = "fullaz.hierarchy-store";
        pub const format_version: u32 = 2;
        pub const page_kind_count: usize = total_page_kinds;
        pub const page_roles: [page_kind_count][]const u8 = buildPageRoles(HierarchyT, options);
        pub const owner_count = options.owners.len;
        pub const type_page_kind_offset = owner_page_kinds;

        pub fn fingerprint(writer: *hierarchy.FingerprintWriter) void {
            writer.writeBytes("fullaz.hierarchy-store.v2");
            writer.writeInt(u32, @intCast(options.owners.len));
            inline for (options.owners) |owner| {
                writer.writeBytes(owner.tag);
                writer.writeInt(u64, owner.owner_id);
                writeDescriptorFingerprint(writer, owner.descriptor);
                const ids = comptime sortedIds(owner.allowed_type_ids);
                writer.writeInt(u32, @intCast(ids.len));
                inline for (ids) |id| writer.writeInt(hierarchy.TypeId, id);
            }
            HierarchyT.writeFingerprint(writer);
        }

        pub fn Binding(comptime BackendT: type) type {
            const Bindings = bindings(HierarchyT, options, BackendT);
            const Runtimes = memberStruct(Bindings, "Runtime");
            const States = memberStruct(Bindings, "TransactionState");
            const OwnerInitOptions = memberStruct(Bindings, "InitOptions");
            const AggregateStorage = staticStorage(Bindings);
            const OwnerTags = knownTags(options);

            const AggregateBinding = struct {
                const Self = @This();

                pub const Proxy = struct {
                    runtime: *Runtime,

                    pub fn owner(self: *const @This(), comptime tag: []const u8) bindingForTag(options, Bindings, tag).Proxy {
                        const index = comptime ownerIndex(options, tag);
                        return Bindings[index].proxy(&@field(self.runtime.owners, ownerField(index)));
                    }

                    pub fn nextInstanceId(self: *const @This()) Error!u64 {
                        const id = self.runtime.next_instance_id;
                        self.runtime.next_instance_id = std.math.add(u64, id, 1) catch return error.InstanceIdExhausted;
                        return id;
                    }
                };
                pub const ConstProxy = struct {
                    runtime: *const Runtime,

                    pub fn owner(self: *const @This(), comptime tag: []const u8) *const bindingForTag(options, Bindings, tag).ConstProxy {
                        const index = comptime ownerIndex(options, tag);
                        return Bindings[index].proxyConst(&@field(self.runtime.owners, ownerField(index)));
                    }
                };
                pub const Runtime = struct {
                    backend: *BackendT,
                    page_kinds: component.PageKindRange,
                    owners: Runtimes,
                    const_proxy: ConstProxy,
                    initialized: usize = 0,
                    next_instance_id: u64 = 1,
                };
                pub const InitOptions = OwnerInitOptions;
                pub const TransactionState = struct {
                    owners: States,
                    next_instance_id: u64,
                };
                pub const Error = errors(Bindings, 0) || error{
                    InvalidPageKinds,
                    InstanceIdExhausted,
                };

                pub const StaticMetadata = struct {
                    pub const Storage = AggregateStorage;
                    pub const Error = staticErrors(Bindings, 0);

                    pub fn capture(runtime: *const Runtime) Storage {
                        var storage: AggregateStorage = undefined;
                        inline for (options.owners, 0..) |_, index| {
                            @field(storage, ownerField(index)) = Bindings[index].StaticMetadata.capture(
                                &@field(runtime.owners, ownerField(index)),
                            );
                        }
                        return storage;
                    }

                    pub fn restore(runtime: *Runtime, storage: *const Storage) void {
                        inline for (options.owners, 0..) |_, index| {
                            Bindings[index].StaticMetadata.restore(
                                &@field(runtime.owners, ownerField(index)),
                                &@field(storage.*, ownerField(index)),
                            );
                        }
                    }

                    pub fn validate(storage: *const Storage, page_count: usize) @This().Error!void {
                        inline for (options.owners, 0..) |_, index| {
                            try Bindings[index].StaticMetadata.validate(
                                &@field(storage.*, ownerField(index)),
                                page_count,
                            );
                        }
                    }
                };

                pub const DynamicMetadata = struct {
                    pub const format_version: u32 = 2;
                    pub const known_tags: []const u16 = &OwnerTags;
                    pub const repeated_tags: []const u16 = &.{};
                    pub const Error = dynamic_metadata.Error;

                    pub fn restore(runtime: *Runtime, payload: []const u8, page_count: usize) @This().Error!void {
                        try tagged.validateKnownFields(payload, known_tags);
                        var storage: AggregateStorage = undefined;
                        var found: [options.owners.len]bool = [_]bool{false} ** options.owners.len;
                        var next: ?u64 = null;
                        var reader = tagged.Reader.init(payload);
                        while (try reader.next()) |field| {
                            inline for (options.owners, 0..) |_, index| {
                                if (field.tag == known_tags[index]) {
                                    if (field.flags != 0 or field.value.len != @sizeOf(Bindings[index].StaticMetadata.Storage)) return error.BadMetadata;
                                    @memcpy(std.mem.asBytes(&@field(storage, ownerField(index))), field.value);
                                    found[index] = true;
                                }
                            }
                            if (field.tag == known_tags[options.owners.len]) next = try dynamic_metadata.readU64(field);
                        }
                        inline for (options.owners, 0..) |_, index| {
                            if (!found[index]) return error.BadMetadata;
                            try Bindings[index].StaticMetadata.validate(&@field(storage, ownerField(index)), page_count);
                            Bindings[index].StaticMetadata.restore(
                                &@field(runtime.owners, ownerField(index)),
                                &@field(storage, ownerField(index)),
                            );
                        }
                        runtime.next_instance_id = next orelse return error.BadMetadata;
                        if (runtime.next_instance_id == 0) return error.BadMetadata;
                    }

                    pub fn encodeKnown(runtime: *const Runtime, writer: *tagged.Writer) @This().Error!void {
                        var storage = StaticMetadata.capture(runtime);
                        inline for (options.owners, 0..) |_, index| {
                            try writer.append(known_tags[index], 0, std.mem.asBytes(&@field(storage, ownerField(index))));
                        }
                        try dynamic_metadata.appendU64(writer, known_tags[options.owners.len], runtime.next_instance_id);
                    }
                };

                pub fn initRuntime(runtime: *Runtime, backend: *BackendT, page_kinds: component.PageKindRange, init_options: InitOptions) Error!void {
                    if (page_kinds.count != page_kind_count) return error.InvalidPageKinds;
                    runtime.* = .{
                        .backend = backend,
                        .page_kinds = page_kinds,
                        .owners = undefined,
                        .const_proxy = undefined,
                    };
                    errdefer deinitInitialized(runtime);
                    inline for (options.owners, 0..) |_, index| {
                        try Bindings[index].initAggregateRuntime(
                            &@field(runtime.owners, ownerField(index)),
                            backend,
                            ownerRange(HierarchyT, page_kinds, options, index) orelse return error.InvalidPageKinds,
                            typeRange(HierarchyT, page_kinds, options) orelse return error.InvalidPageKinds,
                            @field(init_options, ownerField(index)),
                        );
                        runtime.initialized = index + 1;
                    }
                    runtime.const_proxy = .{ .runtime = runtime };
                }

                pub fn deinitRuntime(runtime: *Runtime) void {
                    requireTransactionIdle(runtime) catch @panic("hierarchyStore deinitialized with an active editor");
                    deinitInitialized(runtime);
                    runtime.* = undefined;
                }

                pub fn requireTransactionIdle(runtime: *const Runtime) Error!void {
                    inline for (options.owners, 0..) |_, index| {
                        try Bindings[index].requireTransactionIdle(&@field(runtime.owners, ownerField(index)));
                    }
                }

                pub fn captureTransactionState(runtime: *const Runtime) TransactionState {
                    var states: States = undefined;
                    inline for (options.owners, 0..) |_, index| {
                        @field(states, ownerField(index)) = Bindings[index].captureTransactionState(
                            &@field(runtime.owners, ownerField(index)),
                        );
                    }
                    return .{ .owners = states, .next_instance_id = runtime.next_instance_id };
                }

                pub fn restoreTransactionState(runtime: *Runtime, state: TransactionState) void {
                    inline for (options.owners, 0..) |_, index| {
                        Bindings[index].restoreTransactionState(
                            &@field(runtime.owners, ownerField(index)),
                            @field(state.owners, ownerField(index)),
                        );
                    }
                    runtime.next_instance_id = state.next_instance_id;
                }

                pub fn proxy(runtime: *Runtime) Proxy {
                    return .{ .runtime = runtime };
                }

                pub fn proxyConst(runtime: *const Runtime) *const ConstProxy {
                    return &runtime.const_proxy;
                }

                pub fn reclaimPersistent(runtime: *Runtime) Error!void {
                    try requireTransactionIdle(runtime);
                    inline for (options.owners, 0..) |_, index| {
                        try Bindings[index].reclaimPersistent(&@field(runtime.owners, ownerField(index)));
                    }
                }

                pub fn Gc(comptime CollectorT: type) type {
                    return struct {
                        pub const RootsError = std.mem.Allocator.Error;
                        pub const RegisterError = CollectorT.Error;

                        pub fn appendRoots(runtime: *const Runtime, allocator: std.mem.Allocator, roots: *std.ArrayList(CollectorT.PageId)) RootsError!void {
                            inline for (options.owners, 0..) |_, index| {
                                try Bindings[index].Gc(CollectorT).appendRoots(&@field(runtime.owners, ownerField(index)), allocator, roots);
                            }
                        }

                        pub fn registerScanners(runtime: *const Runtime, collector: *CollectorT) RegisterError!void {
                            inline for (options.owners, 0..) |_, index| {
                                try Bindings[index].Gc(CollectorT).registerScanners(&@field(runtime.owners, ownerField(index)), collector);
                            }
                            try Bindings[0].registerTypeScanners(&@field(runtime.owners, ownerField(0)), collector);
                        }
                    };
                }

                fn deinitInitialized(runtime: *Runtime) void {
                    inline for (options.owners, 0..) |_, index| {
                        if (index < runtime.initialized) Bindings[index].deinitRuntime(&@field(runtime.owners, ownerField(index)));
                    }
                    runtime.initialized = 0;
                }
            };
            comptime component.assertStaticMetadata(AggregateBinding, AggregateBinding.StaticMetadata);
            comptime component.assertDynamicMetadata(AggregateBinding, AggregateBinding.DynamicMetadata);
            comptime component.assertBinding(AggregateBinding, BackendT);
            comptime component.assertReclamation(AggregateBinding);
            return AggregateBinding;
        }
    };
    return component.descriptor(Trait);
}

fn validate(comptime HierarchyT: type, comptime options: hierarchy.StoreOptions) void {
    if (!@hasDecl(HierarchyT, "types")) @compileError("fullaz-db hierarchyStore requires a fullaz-db Hierarchy type");
    if (options.owners.len == 0 or options.owners.len > 0xfefe) @compileError("fullaz-db hierarchyStore requires a supported owner count");
    inline for (options.owners, 0..) |owner, index| {
        if (owner.tag.len == 0 or owner.owner_id == 0) @compileError("fullaz-db hierarchyStore owner tag and owner_id must be non-zero");
        comptime component.assertTrait(owner.descriptor.Trait);
        if (!supported(owner.descriptor.Trait)) @compileError("fullaz-db hierarchyStore owners must be BPT, R-tree, or SlotHeap descriptors");
        inline for (options.owners[0..index]) |prior| {
            if (std.mem.eql(u8, owner.tag, prior.tag)) @compileError("Duplicate fullaz-db hierarchyStore owner tag");
            if (owner.owner_id == prior.owner_id) @compileError("Duplicate fullaz-db hierarchyStore owner ID");
        }
        inline for (owner.allowed_type_ids, 0..) |id, id_index| {
            _ = HierarchyT.entryByTypeId(id);
            inline for (owner.allowed_type_ids[0..id_index]) |prior| {
                if (id == prior) @compileError("Duplicate fullaz-db hierarchyStore allowed type ID");
            }
        }
    }
}

fn supported(comptime Trait: type) bool {
    return (std.mem.eql(u8, Trait.kind_name, "fullaz.bpt.paged") and Trait.page_kind_count == 2) or
        (std.mem.eql(u8, Trait.kind_name, "fullaz.rtree.paged") and Trait.page_kind_count == 2) or
        (std.mem.eql(u8, Trait.kind_name, "fullaz.slot-heap.paged") and Trait.page_kind_count == 3);
}

fn bindings(comptime HierarchyT: type, comptime options: hierarchy.StoreOptions, comptime BackendT: type) [options.owners.len]type {
    var result: [options.owners.len]type = undefined;
    inline for (options.owners, 0..) |owner, index| {
        result[index] = ownerDescriptor(HierarchyT, owner).Trait.Binding(BackendT);
    }
    return result;
}

fn ownerDescriptor(comptime HierarchyT: type, comptime owner: hierarchy.Owner) component.Descriptor {
    if (isBpt(owner.descriptor.Trait)) {
        return hierarchy_owners.bptOwner(HierarchyT, owner.descriptor, owner.allowed_type_ids);
    }
    if (std.mem.eql(u8, owner.descriptor.Trait.kind_name, "fullaz.rtree.paged")) {
        return hierarchy_owners.rtreeOwner(HierarchyT, owner.descriptor, owner.allowed_type_ids);
    }
    return hierarchy_owners.slotHeapOwner(HierarchyT, owner.descriptor, owner.allowed_type_ids);
}

fn isBpt(comptime Trait: type) bool {
    return std.mem.eql(u8, Trait.kind_name, "fullaz.bpt.paged") and Trait.page_kind_count == 2;
}

fn bptOwnerCount(comptime options: hierarchy.StoreOptions) usize {
    var result: usize = 0;
    inline for (options.owners) |owner| {
        if (isBpt(owner.descriptor.Trait)) {
            result += 1;
        }
    }
    return result;
}

fn memberStruct(comptime bindings_: anytype, comptime member: []const u8) type {
    comptime var names: [bindings_.len][]const u8 = undefined;
    comptime var types: [bindings_.len]type = undefined;
    comptime var attributes: [bindings_.len]std.builtin.Type.StructField.Attributes = undefined;
    inline for (bindings_, 0..) |Binding, index| {
        names[index] = ownerField(index);
        types[index] = @field(Binding, member);
        attributes[index] = .{};
    }
    return @Struct(.auto, null, &names, &types, &attributes);
}

fn staticStorage(comptime bindings_: anytype) type {
    comptime var names: [bindings_.len][]const u8 = undefined;
    comptime var types: [bindings_.len]type = undefined;
    comptime var attributes: [bindings_.len]std.builtin.Type.StructField.Attributes = undefined;
    inline for (bindings_, 0..) |Binding, index| {
        names[index] = ownerField(index);
        types[index] = Binding.StaticMetadata.Storage;
        attributes[index] = .{};
    }
    return @Struct(.@"extern", null, &names, &types, &attributes);
}

fn errors(comptime bindings_: anytype, comptime index: usize) type {
    if (index == bindings_.len) return error{};
    return bindings_[index].Error || errors(bindings_, index + 1);
}

fn staticErrors(comptime bindings_: anytype, comptime index: usize) type {
    if (index == bindings_.len) return error{};
    return bindings_[index].StaticMetadata.Error || staticErrors(bindings_, index + 1);
}

fn bindingForTag(comptime options: hierarchy.StoreOptions, comptime bindings_: anytype, comptime tag: []const u8) type {
    return bindings_[ownerIndex(options, tag)];
}

fn ownerIndex(comptime options: hierarchy.StoreOptions, comptime tag: []const u8) usize {
    inline for (options.owners, 0..) |owner, index| if (std.mem.eql(u8, owner.tag, tag)) return index;
    @compileError("Unknown fullaz-db hierarchyStore owner tag: " ++ tag);
}

fn ownerField(comptime index: usize) []const u8 {
    return std.fmt.comptimePrint("owner_{d}", .{index});
}

fn ownerPageKindCount(comptime HierarchyT: type, comptime options: hierarchy.StoreOptions) usize {
    var result: usize = 0;
    inline for (options.owners) |owner| {
        result += ownerDescriptor(HierarchyT, owner).Trait.page_kind_count;
    }
    return result;
}

fn typePageKindCount(comptime HierarchyT: type, comptime options: hierarchy.StoreOptions) usize {
    _ = options;
    var result: usize = 0;
    inline for (HierarchyT.types) |entry| result += entry.descriptor.Trait.page_kind_count;
    return result;
}

fn typeRange(comptime HierarchyT: type, range: component.PageKindRange, comptime options: hierarchy.StoreOptions) ?component.PageKindRange {
    return subrange(range, ownerPageKindCount(HierarchyT, options), typePageKindCount(HierarchyT, options));
}

/// Returns a checked owner subrange inside the aggregate page-kind allocation.
fn ownerRange(comptime HierarchyT: type, range: component.PageKindRange, comptime options: hierarchy.StoreOptions, comptime wanted: usize) ?component.PageKindRange {
    var offset: usize = 0;
    inline for (options.owners[0..wanted]) |owner| {
        offset += ownerDescriptor(HierarchyT, owner).Trait.page_kind_count;
    }
    return subrange(range, offset, ownerDescriptor(HierarchyT, options.owners[wanted]).Trait.page_kind_count);
}

fn subrange(range: component.PageKindRange, offset: usize, count: usize) ?component.PageKindRange {
    const offset_kind = std.math.cast(component.PageKind, offset) orelse return null;
    const count_kind = std.math.cast(component.PageKind, count) orelse return null;
    if (offset_kind > range.count or count_kind > range.count - offset_kind) return null;
    return .{ .base = std.math.add(component.PageKind, range.base, offset_kind) catch return null, .count = count_kind };
}

fn buildPageRoles(comptime HierarchyT: type, comptime options: hierarchy.StoreOptions) [ownerPageKindCount(HierarchyT, options) + typePageKindCount(HierarchyT, options)][]const u8 {
    @setEvalBranchQuota(100_000);
    var roles: [ownerPageKindCount(HierarchyT, options) + typePageKindCount(HierarchyT, options)][]const u8 = undefined;
    var index: usize = 0;
    inline for (options.owners) |owner| {
        inline for (owner.descriptor.Trait.page_roles) |role| {
            roles[index] = std.fmt.comptimePrint("owner.{s}.{s}", .{ owner.tag, role });
            index += 1;
        }
    }
    inline for (HierarchyT.types) |entry| {
        inline for (entry.descriptor.Trait.page_roles) |role| {
            roles[index] = std.fmt.comptimePrint("type.{s}.{s}", .{ entry.tag, role });
            index += 1;
        }
    }
    return roles;
}

fn knownTags(comptime options: hierarchy.StoreOptions) [options.owners.len + 1]u16 {
    var tags: [options.owners.len + 1]u16 = undefined;
    inline for (0..tags.len) |index| tags[index] = @intCast(0x0100 + index);
    return tags;
}

fn writeDescriptorFingerprint(writer: *hierarchy.FingerprintWriter, comptime descriptor: component.Descriptor) void {
    const Trait = descriptor.Trait;
    writer.writeBytes(Trait.kind_name);
    writer.writeInt(u32, Trait.format_version);
    writer.writeInt(u32, @intCast(Trait.page_kind_count));
    inline for (Trait.page_roles) |role| writer.writeBytes(role);
    Trait.fingerprint(writer);
}

fn sortedIds(comptime ids: []const hierarchy.TypeId) [ids.len]hierarchy.TypeId {
    var result: [ids.len]hierarchy.TypeId = undefined;
    inline for (ids, 0..) |id, index| result[index] = id;
    var index: usize = 1;
    while (index < result.len) : (index += 1) {
        const id = result[index];
        var at = index;
        while (at > 0 and id < result[at - 1]) : (at -= 1) result[at] = result[at - 1];
        result[at] = id;
    }
    return result;
}
