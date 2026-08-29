const std = @import("std");
const virtual_page_map_contract = @import("../../contracts/virtual_page_map.zig");

pub fn Memory(
    comptime PhysicalPageIdT: type,
    comptime VirtualPageIdT: type,
) type {
    return struct {
        const Self = @This();
        const PhysicalToVirtual = std.AutoHashMap(PhysicalPageIdT, VirtualPageIdT);

        pub const PhysicalPageIdType = PhysicalPageIdT;
        pub const VirtualPageIdType = VirtualPageIdT;
        pub const Error = std.mem.Allocator.Error || error{
            BatchActive,
            PageIdExhausted,
            VirtualPageNotMapped,
            PhysicalPageAlreadyMapped,
            InconsistentMapping,
        };
        pub const append_only_dense_virtual_page_ids = true;

        pub const WriteBatch = struct {
            cache: *Self,
            virtual_to_physical_snapshot: std.ArrayList(PhysicalPageIdT),
            physical_to_virtual_snapshot: PhysicalToVirtual,
            active: bool = true,

            pub fn commit(self: *WriteBatch) void {
                std.debug.assert(self.active);
                self.virtual_to_physical_snapshot.deinit(self.cache.allocator);
                self.physical_to_virtual_snapshot.deinit();
                self.active = false;
                self.cache.batch_active = false;
            }

            pub fn discard(self: *WriteBatch) void {
                std.debug.assert(self.active);
                self.cache.virtual_to_physical.deinit(self.cache.allocator);
                self.cache.physical_to_virtual.deinit();
                self.cache.virtual_to_physical = self.virtual_to_physical_snapshot;
                self.cache.physical_to_virtual = self.physical_to_virtual_snapshot;
                self.virtual_to_physical_snapshot = .empty;
                self.physical_to_virtual_snapshot = PhysicalToVirtual.init(self.cache.allocator);
                self.active = false;
                self.cache.batch_active = false;
            }

            /// Drops transaction snapshots after the owning cache has entered
            /// a terminal recovery state. The in-memory mapping is no longer
            /// authoritative; reopen resolves it from durable state.
            pub fn abandon(self: *WriteBatch) void {
                std.debug.assert(self.active);
                self.virtual_to_physical_snapshot.deinit(self.cache.allocator);
                self.physical_to_virtual_snapshot.deinit();
                self.active = false;
                self.cache.batch_active = false;
            }
        };

        allocator: std.mem.Allocator,
        virtual_to_physical: std.ArrayList(PhysicalPageIdT) = .empty,
        physical_to_virtual: PhysicalToVirtual,
        batch_active: bool = false,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .physical_to_virtual = PhysicalToVirtual.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.virtual_to_physical.deinit(self.allocator);
            self.physical_to_virtual.deinit();
            self.* = undefined;
        }

        pub fn prepareSet(self: *Self) Error!void {
            _ = try self.nextVirtualPageId();
            try self.virtual_to_physical.ensureUnusedCapacity(self.allocator, 1);
            try self.physical_to_virtual.ensureUnusedCapacity(1);
        }

        pub fn set(self: *Self, physical_page_id: PhysicalPageIdT) Error!VirtualPageIdT {
            if (self.physical_to_virtual.get(physical_page_id)) |virtual_page_id| {
                if (try self.get(virtual_page_id) != physical_page_id) {
                    return error.InconsistentMapping;
                }
                return virtual_page_id;
            }

            const virtual_page_id = try self.nextVirtualPageId();
            try self.prepareSet();
            self.physical_to_virtual.putAssumeCapacityNoClobber(
                physical_page_id,
                virtual_page_id,
            );
            self.virtual_to_physical.appendAssumeCapacity(physical_page_id);
            return virtual_page_id;
        }

        pub fn get(self: *const Self, virtual_page_id: VirtualPageIdT) Error!PhysicalPageIdT {
            const index = std.math.cast(usize, virtual_page_id) orelse return error.VirtualPageNotMapped;
            if (index >= self.virtual_to_physical.items.len) {
                return error.VirtualPageNotMapped;
            }
            const physical_page_id = self.virtual_to_physical.items[index];
            if (self.physical_to_virtual.get(physical_page_id) != virtual_page_id) {
                return error.InconsistentMapping;
            }
            return physical_page_id;
        }

        pub fn remap(
            self: *Self,
            virtual_page_id: VirtualPageIdT,
            physical_page_id: PhysicalPageIdT,
        ) Error!void {
            const index = std.math.cast(usize, virtual_page_id) orelse return error.VirtualPageNotMapped;
            const old_physical_page_id = try self.get(virtual_page_id);
            if (old_physical_page_id == physical_page_id) {
                return;
            }
            if (self.physical_to_virtual.get(physical_page_id) != null) {
                return error.PhysicalPageAlreadyMapped;
            }

            if (!self.physical_to_virtual.remove(old_physical_page_id)) {
                return error.InconsistentMapping;
            }
            self.physical_to_virtual.putAssumeCapacityNoClobber(
                physical_page_id,
                virtual_page_id,
            );
            self.virtual_to_physical.items[index] = physical_page_id;
        }

        pub fn pageCount(self: *const Self) usize {
            return self.virtual_to_physical.items.len;
        }

        pub fn begin(self: *Self) Error!WriteBatch {
            if (self.batch_active) {
                return error.BatchActive;
            }

            var virtual_to_physical_snapshot = try self.virtual_to_physical.clone(self.allocator);
            errdefer virtual_to_physical_snapshot.deinit(self.allocator);

            const physical_to_virtual_snapshot = try self.physical_to_virtual.clone();

            self.batch_active = true;
            return .{
                .cache = self,
                .virtual_to_physical_snapshot = virtual_to_physical_snapshot,
                .physical_to_virtual_snapshot = physical_to_virtual_snapshot,
            };
        }

        pub fn transactionActive(self: *const Self) bool {
            return self.batch_active;
        }

        fn nextVirtualPageId(self: *const Self) Error!VirtualPageIdT {
            const virtual_page_id = std.math.cast(
                VirtualPageIdT,
                self.virtual_to_physical.items.len,
            ) orelse return error.PageIdExhausted;
            if (virtual_page_id == std.math.maxInt(VirtualPageIdT)) {
                return error.PageIdExhausted;
            }
            return virtual_page_id;
        }

        comptime {
            virtual_page_map_contract.assertVirtualPageMap(Self);
        }
    };
}
