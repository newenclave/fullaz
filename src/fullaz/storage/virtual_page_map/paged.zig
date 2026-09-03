const std = @import("std");
const PackedInt = @import("../../core/packed_int.zig").PackedInt;
const core_storage_manager = @import("../../core/storage_manager.zig");
const page_cache_contract = @import("../../contracts/page_cache.zig");
const storage_manager_contract = @import("../../contracts/storage_manager.zig");
const virtual_page_map_contract = @import("../../contracts/virtual_page_map.zig");
const radix_tree = @import("../../radix_tree/radix_tree.zig");

const state_magic = "FZVPM002";
const state_version = 2;

/// Exact durable state required to reopen one paged virtual page map.
pub fn State(
    comptime PhysicalPageIdT: type,
    comptime VirtualPageIdT: type,
) type {
    const PackedVirtualPageId = PackedInt(VirtualPageIdT, .little);
    const PackedU16 = PackedInt(u16, .little);
    const PackedU32 = PackedInt(u32, .little);
    const RadixState = radix_tree.models.paged.State(PhysicalPageIdT, .little);
    const StateImpl = extern struct {
        magic: [state_magic.len]u8,
        version: PackedU16,
        byte_size: PackedU16,
        reserved: PackedU32,
        virtual_to_physical: RadixState,
        physical_to_virtual: RadixState,
        next_virtual_page_id: PackedVirtualPageId,
        crc: PackedU32,
    };

    comptime {
        if (@alignOf(StateImpl) != 1 or
            @sizeOf(StateImpl) > std.math.maxInt(u16) or
            @offsetOf(StateImpl, "magic") != 0 or
            @offsetOf(StateImpl, "version") != @sizeOf([state_magic.len]u8) or
            @offsetOf(StateImpl, "byte_size") !=
                @offsetOf(StateImpl, "version") + @sizeOf(PackedU16) or
            @offsetOf(StateImpl, "reserved") !=
                @offsetOf(StateImpl, "byte_size") + @sizeOf(PackedU16) or
            @offsetOf(StateImpl, "virtual_to_physical") !=
                @offsetOf(StateImpl, "reserved") + @sizeOf(PackedU32) or
            @offsetOf(StateImpl, "physical_to_virtual") !=
                @offsetOf(StateImpl, "virtual_to_physical") + @sizeOf(RadixState) or
            @offsetOf(StateImpl, "next_virtual_page_id") !=
                @offsetOf(StateImpl, "physical_to_virtual") + @sizeOf(RadixState) or
            @offsetOf(StateImpl, "crc") !=
                @offsetOf(StateImpl, "next_virtual_page_id") + @sizeOf(PackedVirtualPageId) or
            @sizeOf(StateImpl) != @offsetOf(StateImpl, "crc") + @sizeOf(PackedU32))
        {
            @compileError("VirtualPageMap paged state layout changed");
        }
    }
    return StateImpl;
}

pub fn Paged(
    comptime PageCacheT: type,
    comptime StorageManagerT: type,
    comptime VirtualPageIdT: type,
) type {
    comptime page_cache_contract.requiresTransactionalPageCache(PageCacheT);
    comptime storage_manager_contract.assertPagedStorageManager(StorageManagerT, PageCacheT.Pid);

    const PhysicalPageIdT = PageCacheT.Pid;
    const PackedPhysicalPageId = PackedInt(PhysicalPageIdT, .little);
    const PackedVirtualPageId = PackedInt(VirtualPageIdT, .little);
    const PackedU32 = PackedInt(u32, .little);
    const StateImpl = State(PhysicalPageIdT, VirtualPageIdT);
    const state_byte_size = @sizeOf(StateImpl);

    comptime {
        assertUnsignedInteger(PhysicalPageIdT, "physical page ID");
        assertUnsignedInteger(VirtualPageIdT, "virtual page ID");
        if (@bitSizeOf(VirtualPageIdT) > @bitSizeOf(usize)) {
            @compileError("VirtualPageMap virtual page ID must fit usize for pageCount");
        }
    }

    return struct {
        const Self = @This();
        const StateLeaseType = StorageManagerT.StateLeaseType;
        const StateView = core_storage_manager.StateAccessor(StateLeaseType, StateImpl);
        const BorrowedOuterStorageManager = core_storage_manager.BorrowedExactPagedStorageManager(
            StorageManagerT,
            StateImpl,
        );
        const VirtualToPhysicalStorageManager = core_storage_manager.PagedFieldStorageManager(
            BorrowedOuterStorageManager,
            StateImpl,
            "virtual_to_physical",
        );
        const PhysicalToVirtualStorageManager = core_storage_manager.PagedFieldStorageManager(
            BorrowedOuterStorageManager,
            StateImpl,
            "physical_to_virtual",
        );

        const VirtualPidSlot = extern struct {
            vid: PackedVirtualPageId,
        };

        const PhysicalPidSlot = extern struct {
            pid: PackedPhysicalPageId,
        };

        const VirtualToPhysicalModel = radix_tree.models.paged.Model(
            PageCacheT,
            VirtualToPhysicalStorageManager,
            VirtualPageIdT,
            @sizeOf(PhysicalPidSlot),
        );
        const VirtualToPhysicalTree = radix_tree.Tree(VirtualToPhysicalModel);

        const PhysicalToVirtualModel = radix_tree.models.paged.Model(
            PageCacheT,
            PhysicalToVirtualStorageManager,
            PhysicalPageIdT,
            @sizeOf(VirtualPidSlot),
        );
        const PhysicalToVirtualTree = radix_tree.Tree(PhysicalToVirtualModel);

        pub const PhysicalPageIdType = PhysicalPageIdT;
        pub const VirtualPageIdType = VirtualPageIdT;

        pub const Settings = struct {
            pub const PageKinds = struct {
                leaf: u16,
                inode: u16,
            };

            virtual_to_physical: PageKinds,
            physical_to_virtual: PageKinds,
        };

        pub const Error = VirtualToPhysicalTree.Error ||
            PhysicalToVirtualTree.Error ||
            PageCacheT.Error ||
            StorageManagerT.Error ||
            StateLeaseType.Error ||
            StateView.Error ||
            error{
                InvalidState,
                UnsupportedStateVersion,
                InvalidSettings,
                TransactionInactive,
                PageIdExhausted,
                VirtualPageNotMapped,
                PhysicalPageAlreadyMapped,
                InconsistentMapping,
            };
        pub const State = StateImpl;
        pub const state_size = state_byte_size;
        pub const append_only_dense_virtual_page_ids = true;

        pub const WriteBatch = struct {
            map: *Self,
            state_snapshot: StateImpl,
            active: bool = true,

            pub fn commit(self: *WriteBatch) void {
                std.debug.assert(self.active);
                self.map.finishBatch(true);
                self.active = false;
            }

            pub fn discard(self: *WriteBatch) void {
                std.debug.assert(self.active);
                self.map.restoreBatchState(&self.state_snapshot);
                self.map.finishBatch(false);
                self.active = false;
            }

            /// Releases the transaction-held state after an inner cache has
            /// entered a terminal recovery state. It deliberately does not
            /// restore the snapshot because durable outcome is now resolved by
            /// WAL replay on the next open.
            pub fn abandon(self: *WriteBatch) void {
                std.debug.assert(self.active);
                self.map.finishBatch(false);
                self.active = false;
            }
        };

        const MutationState = struct {
            lease: ?StateLeaseType = null,

            fn state(self: *MutationState, map: *Self) Error!*StateImpl {
                return StateView.viewMut(self.leasePtr(map));
            }

            fn leasePtr(self: *MutationState, map: *Self) *StateLeaseType {
                if (self.lease) |*lease| {
                    return lease;
                }
                return &map.active_state_lease.?;
            }

            fn publish(self: *MutationState) void {
                if (self.lease) |*lease| {
                    lease.finish();
                }
            }

            pub fn deinit(self: *MutationState) void {
                if (self.lease) |*lease| {
                    lease.deinit();
                    self.lease = null;
                }
            }
        };

        cache: *PageCacheT,
        storage_manager: *StorageManagerT,
        settings: Settings,
        next_virtual_page_id: usize,
        active_state_lease: ?StateLeaseType = null,
        batch_active: bool = false,

        pub fn format(
            cache: *PageCacheT,
            storage_manager: *StorageManagerT,
            settings: Settings,
        ) Error!Self {
            try validateSettings(settings);
            var state_lease = try storage_manager.state();
            defer state_lease.deinit();
            const state = try StateView.viewMut(&state_lease);
            state.* = .{
                .magic = state_magic.*,
                .version = .init(state_version),
                .byte_size = .init(state_byte_size),
                .reserved = .init(0),
                .virtual_to_physical = .{},
                .physical_to_virtual = .{},
                .next_virtual_page_id = .init(0),
                .crc = .init(0),
            };
            sealState(state);
            state_lease.finish();
            return .{
                .cache = cache,
                .storage_manager = storage_manager,
                .settings = settings,
                .next_virtual_page_id = 0,
            };
        }

        pub fn open(
            cache: *PageCacheT,
            storage_manager: *StorageManagerT,
            settings: Settings,
        ) Error!Self {
            try validateSettings(settings);
            var state_lease = try storage_manager.state();
            defer state_lease.deinit();
            const state = try StateView.view(&state_lease);
            try validateState(cache, state);
            return .{
                .cache = cache,
                .storage_manager = storage_manager,
                .settings = settings,
                .next_virtual_page_id = @intCast(state.next_virtual_page_id.get()),
            };
        }

        pub fn deinit(self: *Self) void {
            std.debug.assert(!self.batch_active);
            self.* = undefined;
        }

        pub fn prepareSet(self: *Self) Error!void {
            var mutation = try self.mutationState();
            defer mutation.deinit();
            try self.validateNextVirtualPageId(try mutation.state(self));
        }

        pub fn set(self: *Self, physical_page_id: PhysicalPageIdT) Error!VirtualPageIdT {
            var mutation = try self.mutationState();
            defer mutation.deinit();
            const state = try mutation.state(self);
            const outer_lease = mutation.leasePtr(self);
            if (try self.physicalToVirtualGet(outer_lease, physical_page_id)) |virtual_page_id| {
                if ((try self.virtualToPhysicalGet(outer_lease, virtual_page_id)) != physical_page_id) {
                    return error.InconsistentMapping;
                }
                return virtual_page_id;
            }

            const virtual_page_id = try self.nextVirtualPageId(state);
            if (try self.virtualToPhysicalGet(outer_lease, virtual_page_id) != null) {
                return error.InconsistentMapping;
            }
            errdefer self.cache.markTransactionFailed();
            try self.virtualToPhysicalSet(outer_lease, virtual_page_id, physical_page_id);
            try self.physicalToVirtualSet(outer_lease, physical_page_id, virtual_page_id);
            state.next_virtual_page_id.set(virtual_page_id + 1);
            self.next_virtual_page_id += 1;
            sealState(state);
            mutation.publish();
            return virtual_page_id;
        }

        pub fn get(self: *const Self, virtual_page_id: VirtualPageIdT) Error!PhysicalPageIdT {
            if (self.batch_active) {
                const outer_lease = try self.activeLease();
                return self.getFromState(
                    outer_lease,
                    try StateView.view(outer_lease),
                    virtual_page_id,
                );
            }
            var state_lease = try self.storage_manager.state();
            defer state_lease.deinit();
            const state = try StateView.view(&state_lease);
            try validateState(self.cache, state);
            return self.getFromState(&state_lease, state, virtual_page_id);
        }

        pub fn remap(
            self: *Self,
            virtual_page_id: VirtualPageIdT,
            physical_page_id: PhysicalPageIdT,
        ) Error!void {
            var mutation = try self.mutationState();
            defer mutation.deinit();
            const state = try mutation.state(self);
            const outer_lease = mutation.leasePtr(self);
            const old_physical_page_id = try self.getFromState(
                outer_lease,
                state,
                virtual_page_id,
            );
            if (old_physical_page_id == physical_page_id) {
                return;
            }
            if (try self.physicalToVirtualGet(outer_lease, physical_page_id) != null) {
                return error.PhysicalPageAlreadyMapped;
            }
            errdefer self.cache.markTransactionFailed();
            try self.physicalToVirtualSet(outer_lease, physical_page_id, virtual_page_id);
            try self.virtualToPhysicalSet(outer_lease, virtual_page_id, physical_page_id);
            try self.physicalToVirtualFree(outer_lease, old_physical_page_id);
            sealState(state);
            mutation.publish();
        }

        pub fn pageCount(self: *const Self) usize {
            return self.next_virtual_page_id;
        }

        pub fn begin(self: *Self) Error!WriteBatch {
            if (self.batch_active or !self.cache.transactionActive()) {
                return error.TransactionInactive;
            }
            var state_lease = try self.storage_manager.state();
            errdefer state_lease.deinit();
            const state = try StateView.viewMut(&state_lease);
            try validateState(self.cache, state);
            const state_snapshot = state.*;
            self.active_state_lease = state_lease;
            self.batch_active = true;
            return .{
                .map = self,
                .state_snapshot = state_snapshot,
            };
        }

        pub fn transactionActive(self: *const Self) bool {
            return self.batch_active;
        }

        fn validateSettings(settings: Settings) Error!void {
            const kinds = [_]u16{
                settings.virtual_to_physical.leaf,
                settings.virtual_to_physical.inode,
                settings.physical_to_virtual.leaf,
                settings.physical_to_virtual.inode,
            };
            for (kinds, 0..) |kind, index| {
                for (kinds[index + 1 ..]) |other| {
                    if (kind == other) {
                        return error.InvalidSettings;
                    }
                }
            }
        }

        fn validateState(cache: *const PageCacheT, state: *const StateImpl) Error!void {
            if (!std.mem.eql(u8, &state.magic, state_magic) or
                state.byte_size.get() != state_byte_size or
                state.reserved.get() != 0 or
                crc(state) != state.crc.get())
            {
                return error.InvalidState;
            }
            if (state.version.get() != state_version) {
                return error.UnsupportedStateVersion;
            }
            inline for ([_]PackedPhysicalPageId{
                state.virtual_to_physical.root,
                state.virtual_to_physical.free_leaf_root,
                state.physical_to_virtual.root,
                state.physical_to_virtual.free_leaf_root,
            }) |root| {
                const page_id = root.get();
                if (page_id != std.math.maxInt(PhysicalPageIdT) and
                    page_id >= cache.pageCount())
                {
                    return error.InvalidState;
                }
            }
        }

        fn activeLease(self: *const Self) Error!*StateLeaseType {
            if (!self.batch_active) {
                return error.TransactionInactive;
            }
            return &@constCast(self).active_state_lease.?;
        }

        fn sealState(state: *StateImpl) void {
            state.crc.set(0);
            state.crc.set(crc(state));
        }

        fn crc(state: *const StateImpl) u32 {
            const bytes = std.mem.asBytes(state);
            const crc_offset = @offsetOf(StateImpl, "crc");
            var hasher = std.hash.Crc32.init();
            hasher.update(bytes[0..crc_offset]);
            hasher.update(bytes[crc_offset + @sizeOf(PackedU32) ..]);
            return hasher.final();
        }

        fn mutationState(self: *Self) Error!MutationState {
            if (self.batch_active) {
                return .{};
            }

            var mutation = MutationState{
                .lease = try self.storage_manager.state(),
            };
            errdefer mutation.deinit();
            try validateState(self.cache, try mutation.state(self));
            return mutation;
        }

        fn finishBatch(self: *Self, publish: bool) void {
            const state_lease = &self.active_state_lease.?;
            if (publish) {
                state_lease.finish();
            }
            state_lease.deinit();
            self.active_state_lease = null;
            self.batch_active = false;
        }

        fn restoreBatchState(self: *Self, state_snapshot: *const StateImpl) void {
            const state = StateView.viewMut(&self.active_state_lease.?) catch {
                @panic("VirtualPageMap batch state became inaccessible");
            };
            state.* = state_snapshot.*;
            self.next_virtual_page_id = @intCast(state_snapshot.next_virtual_page_id.get());
        }

        fn validateNextVirtualPageId(self: *const Self, state: *const StateImpl) Error!void {
            if (state.next_virtual_page_id.get() == std.math.maxInt(VirtualPageIdT)) {
                return error.PageIdExhausted;
            }
            if (@as(usize, @intCast(state.next_virtual_page_id.get())) != self.next_virtual_page_id) {
                return error.InconsistentMapping;
            }
        }

        fn nextVirtualPageId(self: *const Self, state: *const StateImpl) Error!VirtualPageIdT {
            try self.validateNextVirtualPageId(state);
            return state.next_virtual_page_id.get();
        }

        fn getFromState(
            self: *const Self,
            outer_lease: *StateLeaseType,
            state: *const StateImpl,
            virtual_page_id: VirtualPageIdT,
        ) Error!PhysicalPageIdT {
            if (virtual_page_id >= state.next_virtual_page_id.get()) {
                return error.VirtualPageNotMapped;
            }

            const physical_page_id = try self.virtualToPhysicalGet(outer_lease, virtual_page_id) orelse
                return error.InconsistentMapping;

            const reverse_virtual_page_id = try self.physicalToVirtualGet(outer_lease, physical_page_id) orelse
                return error.InconsistentMapping;

            if (reverse_virtual_page_id != virtual_page_id) {
                return error.InconsistentMapping;
            }

            return physical_page_id;
        }

        fn virtualToPhysicalGet(
            self: *const Self,
            outer_lease: *StateLeaseType,
            virtual_page_id: VirtualPageIdT,
        ) Error!?PhysicalPageIdT {
            var borrowed_manager = BorrowedOuterStorageManager.init(
                self.storage_manager,
                outer_lease,
            );
            var projected_manager = VirtualToPhysicalStorageManager.init(&borrowed_manager);
            var model = try VirtualToPhysicalModel.init(self.cache, &projected_manager, .{
                .leaf_page_kind = self.settings.virtual_to_physical.leaf,
                .inode_page_kind = self.settings.virtual_to_physical.inode,
            });
            defer model.deinit();
            var tree = VirtualToPhysicalTree.init(&model);
            defer tree.deinit();
            const bytes = (try tree.get(virtual_page_id)) orelse return null;
            if (bytes.len != @sizeOf(PhysicalPidSlot)) {
                return error.InconsistentMapping;
            }
            const slot: *const PhysicalPidSlot = @ptrCast(bytes.ptr);
            return slot.pid.get();
        }

        fn virtualToPhysicalSet(
            self: *Self,
            outer_lease: *StateLeaseType,
            virtual_page_id: VirtualPageIdT,
            physical_page_id: PhysicalPageIdT,
        ) Error!void {
            var borrowed_manager = BorrowedOuterStorageManager.init(
                self.storage_manager,
                outer_lease,
            );
            var projected_manager = VirtualToPhysicalStorageManager.init(&borrowed_manager);
            var model = try VirtualToPhysicalModel.init(self.cache, &projected_manager, .{
                .leaf_page_kind = self.settings.virtual_to_physical.leaf,
                .inode_page_kind = self.settings.virtual_to_physical.inode,
            });
            defer model.deinit();
            var tree = VirtualToPhysicalTree.init(&model);
            defer tree.deinit();

            const slot = PhysicalPidSlot{
                .pid = .init(physical_page_id),
            };
            try tree.set(virtual_page_id, std.mem.asBytes(&slot));
        }

        fn physicalToVirtualGet(
            self: *const Self,
            outer_lease: *StateLeaseType,
            physical_page_id: PhysicalPageIdT,
        ) Error!?VirtualPageIdT {
            var borrowed_manager = BorrowedOuterStorageManager.init(
                self.storage_manager,
                outer_lease,
            );
            var projected_manager = PhysicalToVirtualStorageManager.init(&borrowed_manager);
            var model = try PhysicalToVirtualModel.init(self.cache, &projected_manager, .{
                .leaf_page_kind = self.settings.physical_to_virtual.leaf,
                .inode_page_kind = self.settings.physical_to_virtual.inode,
            });
            defer model.deinit();
            var tree = PhysicalToVirtualTree.init(&model);
            defer tree.deinit();
            const bytes = (try tree.get(physical_page_id)) orelse return null;
            if (bytes.len != @sizeOf(VirtualPidSlot)) {
                return error.InconsistentMapping;
            }
            const slot: *const VirtualPidSlot = @ptrCast(bytes.ptr);
            return slot.vid.get();
        }

        fn physicalToVirtualSet(
            self: *Self,
            outer_lease: *StateLeaseType,
            physical_page_id: PhysicalPageIdT,
            virtual_page_id: VirtualPageIdT,
        ) Error!void {
            var borrowed_manager = BorrowedOuterStorageManager.init(
                self.storage_manager,
                outer_lease,
            );
            var projected_manager = PhysicalToVirtualStorageManager.init(&borrowed_manager);
            var model = try PhysicalToVirtualModel.init(self.cache, &projected_manager, .{
                .leaf_page_kind = self.settings.physical_to_virtual.leaf,
                .inode_page_kind = self.settings.physical_to_virtual.inode,
            });
            defer model.deinit();
            var tree = PhysicalToVirtualTree.init(&model);
            defer tree.deinit();
            const slot = VirtualPidSlot{
                .vid = .init(virtual_page_id),
            };
            try tree.set(physical_page_id, std.mem.asBytes(&slot));
        }

        fn physicalToVirtualFree(
            self: *Self,
            outer_lease: *StateLeaseType,
            physical_page_id: PhysicalPageIdT,
        ) Error!void {
            var borrowed_manager = BorrowedOuterStorageManager.init(
                self.storage_manager,
                outer_lease,
            );
            var projected_manager = PhysicalToVirtualStorageManager.init(&borrowed_manager);
            var model = try PhysicalToVirtualModel.init(self.cache, &projected_manager, .{
                .leaf_page_kind = self.settings.physical_to_virtual.leaf,
                .inode_page_kind = self.settings.physical_to_virtual.inode,
            });
            defer model.deinit();
            var tree = PhysicalToVirtualTree.init(&model);
            defer tree.deinit();
            try tree.free(physical_page_id);
        }

        comptime {
            virtual_page_map_contract.assertVirtualPageMap(Self);
        }
    };
}

fn assertUnsignedInteger(comptime T: type, comptime name: []const u8) void {
    switch (@typeInfo(T)) {
        .int => |integer| {
            if (integer.signedness != .unsigned) {
                @compileError("VirtualPageMap " ++ name ++ " must be unsigned");
            }
        },
        else => @compileError("VirtualPageMap " ++ name ++ " must be an integer"),
    }
}
