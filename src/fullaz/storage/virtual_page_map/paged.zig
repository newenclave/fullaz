const std = @import("std");
const PackedInt = @import("../../core/packed_int.zig").PackedInt;
const page_cache_contract = @import("../../contracts/page_cache.zig");
const storage_manager_contract = @import("../../contracts/storage_manager.zig");
const virtual_page_map_contract = @import("../../contracts/virtual_page_map.zig");
const radix_tree = @import("../../radix_tree/radix_tree.zig");

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
    const PackedU16 = PackedInt(u16, .little);
    const PackedU32 = PackedInt(u32, .little);
    const nil_physical_page_id = std.math.maxInt(PhysicalPageIdT);
    const state_magic = "FZVPM001";
    const state_version = 1;

    const State = extern struct {
        magic: [state_magic.len]u8,
        version: PackedU16,
        byte_size: PackedU16,
        reserved: PackedU32,
        virtual_to_physical_root: PackedPhysicalPageId,
        virtual_to_physical_free_leaf_root: PackedPhysicalPageId,
        physical_to_virtual_root: PackedPhysicalPageId,
        physical_to_virtual_free_leaf_root: PackedPhysicalPageId,
        next_virtual_page_id: PackedVirtualPageId,
    };
    const state_byte_size = @sizeOf(State);

    comptime {
        assertUnsignedInteger(PhysicalPageIdT, "physical page ID");
        assertUnsignedInteger(VirtualPageIdT, "virtual page ID");
        if (@bitSizeOf(VirtualPageIdT) > @bitSizeOf(usize)) {
            @compileError("VirtualPageMap virtual page ID must fit usize for pageCount");
        }
        if (@alignOf(State) != 1 or
            state_byte_size > std.math.maxInt(u16) or
            @offsetOf(State, "magic") != 0 or
            @offsetOf(State, "version") != @sizeOf([state_magic.len]u8) or
            @offsetOf(State, "byte_size") != @offsetOf(State, "version") + @sizeOf(PackedU16) or
            @offsetOf(State, "reserved") != @offsetOf(State, "byte_size") + @sizeOf(PackedU16) or
            @offsetOf(State, "virtual_to_physical_root") != @offsetOf(State, "reserved") + @sizeOf(PackedU32) or
            @offsetOf(State, "virtual_to_physical_free_leaf_root") != @offsetOf(State, "virtual_to_physical_root") + @sizeOf(PackedPhysicalPageId) or
            @offsetOf(State, "physical_to_virtual_root") != @offsetOf(State, "virtual_to_physical_free_leaf_root") + @sizeOf(PackedPhysicalPageId) or
            @offsetOf(State, "physical_to_virtual_free_leaf_root") != @offsetOf(State, "physical_to_virtual_root") + @sizeOf(PackedPhysicalPageId) or
            @offsetOf(State, "next_virtual_page_id") != @offsetOf(State, "physical_to_virtual_free_leaf_root") + @sizeOf(PackedPhysicalPageId))
        {
            @compileError("VirtualPageMap paged state layout changed");
        }
    }

    return struct {
        const Self = @This();
        const StateLeaseType = StorageManagerT.StateLeaseType;

        const VirtualToPhysicalStorageManager = struct {
            pub const PageId = PhysicalPageIdT;
            const ManagerError = StorageManagerT.Error;

            pub const Error = ManagerError;

            state: *State,
            common: *StorageManagerT,

            pub fn getRoot(self: *const @This()) ?PageId {
                const page_id = self.state.virtual_to_physical_root.get();
                return if (page_id == nil_physical_page_id) null else page_id;
            }

            pub fn setRoot(self: *@This(), page_id: ?PageId) ManagerError!void {
                self.state.virtual_to_physical_root.set(page_id orelse nil_physical_page_id);
            }

            pub fn getFreeLeafRoot(self: *const @This()) ?PageId {
                const page_id = self.state.virtual_to_physical_free_leaf_root.get();
                return if (page_id == nil_physical_page_id) null else page_id;
            }

            pub fn setFreeLeafRoot(self: *@This(), page_id: ?PageId) ManagerError!void {
                self.state.virtual_to_physical_free_leaf_root.set(page_id orelse nil_physical_page_id);
            }

            pub fn destroyPage(self: *@This(), page_id: PageId) ManagerError!void {
                return self.common.destroyPage(page_id);
            }
        };

        const PhysicalToVirtualStorageManager = struct {
            pub const PageId = PhysicalPageIdT;
            const ManagerError = StorageManagerT.Error;

            pub const Error = ManagerError;

            state: *State,
            common: *StorageManagerT,

            pub fn getRoot(self: *const @This()) ?PageId {
                const page_id = self.state.physical_to_virtual_root.get();
                return if (page_id == nil_physical_page_id) null else page_id;
            }

            pub fn setRoot(self: *@This(), page_id: ?PageId) ManagerError!void {
                self.state.physical_to_virtual_root.set(page_id orelse nil_physical_page_id);
            }

            pub fn getFreeLeafRoot(self: *const @This()) ?PageId {
                const page_id = self.state.physical_to_virtual_free_leaf_root.get();
                return if (page_id == nil_physical_page_id) null else page_id;
            }

            pub fn setFreeLeafRoot(self: *@This(), page_id: ?PageId) ManagerError!void {
                self.state.physical_to_virtual_free_leaf_root.set(page_id orelse nil_physical_page_id);
            }

            pub fn destroyPage(self: *@This(), page_id: PageId) ManagerError!void {
                return self.common.destroyPage(page_id);
            }
        };

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
            error{
                StateTooSmall,
                InvalidState,
                UnsupportedStateVersion,
                InvalidSettings,
                TransactionInactive,
                PageIdExhausted,
                VirtualPageNotMapped,
                PhysicalPageAlreadyMapped,
                InconsistentMapping,
            };
        pub const state_size = state_byte_size;
        pub const append_only_dense_virtual_page_ids = true;

        pub const WriteBatch = struct {
            map: *Self,
            state_snapshot: [state_byte_size]u8,
            active: bool = true,

            pub fn commit(self: *WriteBatch) void {
                std.debug.assert(self.active);
                self.map.finishBatch();
                self.active = false;
            }

            pub fn discard(self: *WriteBatch) void {
                std.debug.assert(self.active);
                self.map.restoreBatchState(&self.state_snapshot);
                self.map.finishBatch();
                self.active = false;
            }
        };

        cache: *PageCacheT,
        storage_manager: *StorageManagerT,
        settings: Settings,
        next_virtual_page_id: usize,
        active_state_lease: ?StateLeaseType = null,
        active_state_bytes: ?[]u8 = null,
        batch_active: bool = false,

        pub fn format(
            cache: *PageCacheT,
            storage_manager: *StorageManagerT,
            settings: Settings,
        ) Error!Self {
            try validateSettings(settings);
            var state_lease = try storage_manager.state();
            defer state_lease.deinit();
            const bytes = try state_lease.dataMut();
            const state = try stateMut(bytes);
            @memset(bytes[0..state_byte_size], 0);
            state.* = .{
                .magic = state_magic.*,
                .version = .init(state_version),
                .byte_size = .init(state_byte_size),
                .reserved = .init(0),
                .virtual_to_physical_root = .init(nil_physical_page_id),
                .virtual_to_physical_free_leaf_root = .init(nil_physical_page_id),
                .physical_to_virtual_root = .init(nil_physical_page_id),
                .physical_to_virtual_free_leaf_root = .init(nil_physical_page_id),
                .next_virtual_page_id = .init(0),
            };
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
            const state = try stateView(try state_lease.data());
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
            const state = try self.activeState();
            try self.validateNextVirtualPageId(state);
        }

        pub fn set(self: *Self, physical_page_id: PhysicalPageIdT) Error!VirtualPageIdT {
            const state = try self.activeState();
            if (try self.physicalToVirtualGet(state, physical_page_id)) |virtual_page_id| {
                if ((try self.virtualToPhysicalGet(state, virtual_page_id)) != physical_page_id) {
                    return error.InconsistentMapping;
                }
                return virtual_page_id;
            }

            const virtual_page_id = try self.nextVirtualPageId(state);
            if (try self.virtualToPhysicalGet(state, virtual_page_id) != null) {
                return error.InconsistentMapping;
            }
            errdefer self.cache.markTransactionFailed();
            try self.virtualToPhysicalSet(state, virtual_page_id, physical_page_id);
            try self.physicalToVirtualSet(state, physical_page_id, virtual_page_id);
            state.next_virtual_page_id.set(virtual_page_id + 1);
            self.next_virtual_page_id += 1;
            return virtual_page_id;
        }

        pub fn get(self: *const Self, virtual_page_id: VirtualPageIdT) Error!PhysicalPageIdT {
            if (self.batch_active) {
                return self.getFromState(try self.activeStateConst(), virtual_page_id);
            }
            var state_lease = try self.storage_manager.state();
            defer state_lease.deinit();
            const state = try stateView(try state_lease.data());
            try validateState(self.cache, state);
            return self.getFromState(state, virtual_page_id);
        }

        pub fn remap(
            self: *Self,
            virtual_page_id: VirtualPageIdT,
            physical_page_id: PhysicalPageIdT,
        ) Error!void {
            const state = try self.activeState();
            const old_physical_page_id = try self.getFromState(state, virtual_page_id);
            if (old_physical_page_id == physical_page_id) {
                return;
            }
            if (try self.physicalToVirtualGet(state, physical_page_id) != null) {
                return error.PhysicalPageAlreadyMapped;
            }
            errdefer self.cache.markTransactionFailed();
            try self.physicalToVirtualSet(state, physical_page_id, virtual_page_id);
            try self.virtualToPhysicalSet(state, virtual_page_id, physical_page_id);
            try self.physicalToVirtualFree(state, old_physical_page_id);
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
            const bytes = try state_lease.dataMut();
            const state = try stateMut(bytes);
            try validateState(self.cache, state);
            var state_snapshot: [state_byte_size]u8 = undefined;
            @memcpy(&state_snapshot, bytes[0..state_byte_size]);
            self.active_state_lease = state_lease;
            self.active_state_bytes = bytes;
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

        fn validateState(cache: *const PageCacheT, state: *const State) Error!void {
            if (!std.mem.eql(u8, &state.magic, state_magic) or
                state.byte_size.get() != state_byte_size or
                state.reserved.get() != 0)
            {
                return error.InvalidState;
            }
            if (state.version.get() != state_version) {
                return error.UnsupportedStateVersion;
            }
            inline for ([_]PackedPhysicalPageId{
                state.virtual_to_physical_root,
                state.virtual_to_physical_free_leaf_root,
                state.physical_to_virtual_root,
                state.physical_to_virtual_free_leaf_root,
            }) |root| {
                const page_id = root.get();
                if (page_id != nil_physical_page_id and page_id >= cache.pageCount()) {
                    return error.InvalidState;
                }
            }
        }

        fn activeState(self: *Self) Error!*State {
            if (!self.batch_active) {
                return error.TransactionInactive;
            }
            return stateMut(self.active_state_bytes orelse unreachable);
        }

        fn activeStateConst(self: *const Self) Error!*const State {
            if (!self.batch_active) {
                return error.TransactionInactive;
            }
            return stateView(self.active_state_bytes orelse unreachable);
        }

        fn finishBatch(self: *Self) void {
            var state_lease = self.active_state_lease orelse unreachable;
            self.active_state_lease = null;
            self.active_state_bytes = null;
            self.batch_active = false;
            state_lease.deinit();
        }

        fn restoreBatchState(self: *Self, state_snapshot: *const [state_byte_size]u8) void {
            const bytes = self.active_state_bytes orelse unreachable;
            @memcpy(bytes[0..state_byte_size], state_snapshot);
            const state: *const State = @ptrCast(state_snapshot);
            self.next_virtual_page_id = @intCast(state.next_virtual_page_id.get());
        }

        fn validateNextVirtualPageId(self: *const Self, state: *const State) Error!void {
            if (state.next_virtual_page_id.get() == std.math.maxInt(VirtualPageIdT)) {
                return error.PageIdExhausted;
            }
            if (@as(usize, @intCast(state.next_virtual_page_id.get())) != self.next_virtual_page_id) {
                return error.InconsistentMapping;
            }
        }

        fn nextVirtualPageId(self: *const Self, state: *const State) Error!VirtualPageIdT {
            try self.validateNextVirtualPageId(state);
            return state.next_virtual_page_id.get();
        }

        fn getFromState(self: *const Self, state: *const State, virtual_page_id: VirtualPageIdT) Error!PhysicalPageIdT {
            if (virtual_page_id >= state.next_virtual_page_id.get()) {
                return error.VirtualPageNotMapped;
            }
            const mutable_state = @constCast(state);

            const physical_page_id = try self.virtualToPhysicalGet(mutable_state, virtual_page_id) orelse
                return error.InconsistentMapping;

            const reverse_virtual_page_id = try self.physicalToVirtualGet(mutable_state, physical_page_id) orelse
                return error.InconsistentMapping;

            if (reverse_virtual_page_id != virtual_page_id) {
                return error.InconsistentMapping;
            }

            return physical_page_id;
        }

        fn virtualToPhysicalGet(
            self: *const Self,
            state: *State,
            virtual_page_id: VirtualPageIdT,
        ) Error!?PhysicalPageIdT {
            var storage_manager = VirtualToPhysicalStorageManager{
                .state = state,
                .common = self.storage_manager,
            };
            var model = try VirtualToPhysicalModel.init(self.cache, &storage_manager, .{
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
            state: *State,
            virtual_page_id: VirtualPageIdT,
            physical_page_id: PhysicalPageIdT,
        ) Error!void {
            var storage_manager = VirtualToPhysicalStorageManager{
                .state = state,
                .common = self.storage_manager,
            };
            var model = try VirtualToPhysicalModel.init(self.cache, &storage_manager, .{
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
            state: *State,
            physical_page_id: PhysicalPageIdT,
        ) Error!?VirtualPageIdT {
            var storage_manager = PhysicalToVirtualStorageManager{
                .state = state,
                .common = self.storage_manager,
            };
            var model = try PhysicalToVirtualModel.init(self.cache, &storage_manager, .{
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

        fn physicalToVirtualSet(self: *Self, state: *State, physical_page_id: PhysicalPageIdT, virtual_page_id: VirtualPageIdT) Error!void {
            var storage_manager = PhysicalToVirtualStorageManager{
                .state = state,
                .common = self.storage_manager,
            };
            var model = try PhysicalToVirtualModel.init(self.cache, &storage_manager, .{
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

        fn physicalToVirtualFree(self: *Self, state: *State, physical_page_id: PhysicalPageIdT) Error!void {
            var storage_manager = PhysicalToVirtualStorageManager{
                .state = state,
                .common = self.storage_manager,
            };
            var model = try PhysicalToVirtualModel.init(self.cache, &storage_manager, .{
                .leaf_page_kind = self.settings.physical_to_virtual.leaf,
                .inode_page_kind = self.settings.physical_to_virtual.inode,
            });
            defer model.deinit();
            var tree = PhysicalToVirtualTree.init(&model);
            defer tree.deinit();
            try tree.free(physical_page_id);
        }

        fn stateView(bytes: []const u8) Error!*const State {
            if (bytes.len < state_byte_size) {
                return error.StateTooSmall;
            }
            return @ptrCast(bytes.ptr);
        }

        fn stateMut(bytes: []u8) Error!*State {
            if (bytes.len < state_byte_size) {
                return error.StateTooSmall;
            }
            return @ptrCast(bytes.ptr);
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
