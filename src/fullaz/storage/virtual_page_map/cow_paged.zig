const std = @import("std");
const PackedInt = @import("../../core/packed_int.zig").PackedInt;
const page_cache_contract = @import("../../contracts/page_cache.zig");
const virtual_page_map_contract = @import("../../contracts/virtual_page_map.zig");

/// An append-only, copy-on-write virtual page map. Each mutation copies only
/// the radix path from the changed VID to the current root.
pub fn CowPaged(comptime PageCacheT: type, comptime VirtualPageIdT: type) type {
    comptime page_cache_contract.requiresTransactionalPageCache(PageCacheT);
    comptime {
        const type_info = @typeInfo(VirtualPageIdT);
        if (type_info != .int or type_info.int.signedness != .unsigned) {
            @compileError("CowPaged virtual page ID must be an unsigned integer");
        }
        if (@bitSizeOf(VirtualPageIdT) > @bitSizeOf(usize)) {
            @compileError("CowPaged virtual page ID must fit usize");
        }
    }

    const PhysicalPageId = PageCacheT.Pid;
    const PackedPhysicalPageId = PackedInt(PhysicalPageId, .little);
    const PackedU16 = PackedInt(u16, .little);
    const nil_page_id = std.math.maxInt(PhysicalPageId);
    const node_magic = "FZCOWPM1";
    const node_version = 1;

    const NodeHeader = extern struct {
        magic: [node_magic.len]u8,
        version: PackedU16,
        header_size: PackedU16,
        level: PackedU16,
        reserved: PackedU16,
        self_pid: PackedPhysicalPageId,
    };

    return struct {
        const Self = @This();

        pub const PhysicalPageIdType = PhysicalPageId;
        pub const VirtualPageIdType = VirtualPageIdT;
        pub const append_only_dense_virtual_page_ids = true;
        pub const Snapshot = struct {
            root_page_id: ?PhysicalPageId,
            root_level: u16,
            next_virtual_page_id: VirtualPageIdT,
        };
        pub const Error = PageCacheT.Error || error{
            BatchActive,
            TransactionInactive,
            PageIdExhausted,
            VirtualPageNotMapped,
            InconsistentMapping,
            InvalidNode,
            UnsupportedNodeVersion,
            NodeLevelMismatch,
            NodeTooSmall,
        };

        pub const WriteBatch = struct {
            map: *Self,
            snapshot: Snapshot,
            active: bool = true,

            pub fn commit(self: *WriteBatch) void {
                std.debug.assert(self.active);
                self.active = false;
                self.map.batch_active = false;
            }

            pub fn discard(self: *WriteBatch) void {
                std.debug.assert(self.active);
                self.map.snapshot = self.snapshot;
                self.active = false;
                self.map.batch_active = false;
            }

            /// The backing cache has a terminal failure and the next open
            /// selects a durable superblock generation instead of this state.
            pub fn abandon(self: *WriteBatch) void {
                std.debug.assert(self.active);
                self.active = false;
                self.map.batch_active = false;
            }
        };

        cache: *PageCacheT,
        snapshot: Snapshot,
        remap_context: PageCacheT.PidPolicyType.RemapContextType,
        batch_active: bool = false,

        pub fn init(
            cache: *PageCacheT,
            snapshot: Snapshot,
            remap_context: PageCacheT.PidPolicyType.RemapContextType,
        ) Error!Self {
            const self = Self{
                .cache = cache,
                .snapshot = snapshot,
                .remap_context = remap_context,
            };
            try self.validateSnapshot();
            return self;
        }

        pub fn deinit(self: *Self) void {
            std.debug.assert(!self.batch_active);
            self.* = undefined;
        }

        pub fn currentSnapshot(self: *const Self) Snapshot {
            return self.snapshot;
        }

        pub fn prepareSet(self: *Self) Error!void {
            try self.requireActive();
            _ = try self.nextVirtualPageId();
        }

        pub fn set(self: *Self, physical_page_id: PhysicalPageId) Error!VirtualPageIdT {
            try self.requireActive();
            const virtual_page_id = try self.nextVirtualPageId();
            try self.writeMapping(virtual_page_id, physical_page_id);
            self.snapshot.next_virtual_page_id = virtual_page_id + 1;
            return virtual_page_id;
        }

        pub fn get(self: *const Self, virtual_page_id: VirtualPageIdT) Error!PhysicalPageId {
            if (virtual_page_id >= self.snapshot.next_virtual_page_id) {
                return error.VirtualPageNotMapped;
            }
            var page_id = self.snapshot.root_page_id orelse return error.InvalidNode;
            var level = self.snapshot.root_level;
            while (true) {
                var handle = try self.cache.fetch(page_id);
                defer handle.deinit();
                const bytes = try handle.data();
                try self.validateNode(bytes, page_id, level);
                const slots = try self.slotsConst(bytes);
                const child_page_id = slots[self.digit(virtual_page_id, level)].get();
                if (child_page_id == nil_page_id) {
                    return error.VirtualPageNotMapped;
                }
                if (level == 0) {
                    return child_page_id;
                }
                page_id = child_page_id;
                level -= 1;
            }
        }

        pub fn remap(
            self: *Self,
            virtual_page_id: VirtualPageIdT,
            physical_page_id: PhysicalPageId,
        ) Error!void {
            try self.requireActive();
            _ = try self.get(virtual_page_id);
            try self.writeMapping(virtual_page_id, physical_page_id);
        }

        pub fn pageCount(self: *const Self) usize {
            return @intCast(self.snapshot.next_virtual_page_id);
        }

        pub fn begin(self: *Self) Error!WriteBatch {
            if (self.batch_active or !self.cache.transactionActive()) {
                return error.TransactionInactive;
            }
            self.batch_active = true;
            return .{
                .map = self,
                .snapshot = self.snapshot,
            };
        }

        pub fn transactionActive(self: *const Self) bool {
            return self.batch_active;
        }

        /// Visits every map node and mapped data PID reachable from `snapshot`.
        /// The visitor must not mutate the cache while scanning.
        pub fn scanSnapshot(
            self: *Self,
            snapshot: Snapshot,
            context: anytype,
            comptime visit: fn (@TypeOf(context), PhysicalPageId) void,
        ) Error!void {
            if (snapshot.root_page_id) |root_page_id| {
                try self.scanNode(root_page_id, snapshot.root_level, context, visit);
            }
        }

        fn writeMapping(
            self: *Self,
            virtual_page_id: VirtualPageIdT,
            physical_page_id: PhysicalPageId,
        ) Error!void {
            const required_level = try self.requiredRootLevel(virtual_page_id);
            var root_page_id = self.snapshot.root_page_id;
            var root_level = self.snapshot.root_level;
            while (root_page_id != null and root_level < required_level) {
                const new_root_page_id = try self.createNode(root_level + 1);
                var root = try self.cache.fetch(new_root_page_id);
                defer root.deinit();
                const bytes = try root.dataMut();
                const slots = try self.slotsMut(bytes);
                slots[0].set(root_page_id.?);
                root_level += 1;
                root_page_id = new_root_page_id;
            }
            if (root_page_id == null) {
                root_page_id = try self.createNode(required_level);
                root_level = required_level;
            }
            self.snapshot.root_page_id = try self.mutatePath(
                root_page_id.?,
                root_level,
                virtual_page_id,
                physical_page_id,
            );
            self.snapshot.root_level = root_level;
        }

        fn mutatePath(
            self: *Self,
            page_id: PhysicalPageId,
            level: u16,
            virtual_page_id: VirtualPageIdT,
            physical_page_id: PhysicalPageId,
        ) Error!PhysicalPageId {
            var node = try self.writableNode(page_id, level);
            defer node.deinit();
            const node_page_id = try node.pid();
            const bytes = try node.dataMut();
            const slots = try self.slotsMut(bytes);
            const slot_index = self.digit(virtual_page_id, level);
            if (level == 0) {
                slots[slot_index].set(physical_page_id);
            } else {
                const child_page_id = slots[slot_index].get();
                if (child_page_id == nil_page_id) {
                    slots[slot_index].set(try self.createNode(level - 1));
                }
                slots[slot_index].set(try self.mutatePath(
                    slots[slot_index].get(),
                    level - 1,
                    virtual_page_id,
                    physical_page_id,
                ));
            }
            return node_page_id;
        }

        fn writableNode(self: *Self, page_id: PhysicalPageId, level: u16) Error!PageCacheT.Handle {
            var node = try self.cache.fetch(page_id);
            errdefer node.deinit();
            try self.validateNode(try node.data(), page_id, level);

            var fork = try self.cache.prepareBackingFork(page_id, self.remap_context);
            if (fork) |*pending| {
                self.cache.commitBackingFork(pending);
                const bytes = try node.dataMut();
                const header = try self.headerMut(bytes);
                header.self_pid.set(try node.pid());
            }
            return node;
        }

        fn scanNode(
            self: *Self,
            page_id: PhysicalPageId,
            level: u16,
            context: anytype,
            comptime visit: fn (@TypeOf(context), PhysicalPageId) void,
        ) Error!void {
            if (@as(usize, @intCast(page_id)) >= self.cache.pageCount()) {
                return error.InvalidNode;
            }
            visit(context, page_id);
            var node = try self.cache.fetch(page_id);
            defer node.deinit();
            const bytes = try node.data();
            try self.validateNode(bytes, page_id, level);
            const slots = try self.slotsConst(bytes);
            for (slots) |slot| {
                const child_page_id = slot.get();
                if (child_page_id == nil_page_id) {
                    continue;
                }
                if (level == 0) {
                    if (@as(usize, @intCast(child_page_id)) >= self.cache.pageCount()) {
                        return error.InvalidNode;
                    }
                    visit(context, child_page_id);
                } else {
                    try self.scanNode(child_page_id, level - 1, context, visit);
                }
            }
        }

        fn createNode(self: *Self, level: u16) Error!PhysicalPageId {
            var handle = try self.cache.create();
            defer handle.deinit();
            const page_id = try handle.pid();
            const bytes = try handle.dataMut();
            const slots = try self.slotsMut(bytes);
            @memset(bytes, 0);
            const header = try self.headerMut(bytes);
            header.* = .{
                .magic = node_magic.*,
                .version = .init(node_version),
                .header_size = .init(@sizeOf(NodeHeader)),
                .level = .init(level),
                .reserved = .init(0),
                .self_pid = .init(page_id),
            };
            for (slots) |*slot| {
                slot.set(nil_page_id);
            }
            return page_id;
        }

        fn validateSnapshot(self: *const Self) Error!void {
            if (self.snapshot.next_virtual_page_id == 0) {
                if (self.snapshot.root_page_id != null or self.snapshot.root_level != 0) {
                    return error.InvalidNode;
                }
                return;
            }
            const root_page_id = self.snapshot.root_page_id orelse return error.InvalidNode;
            if (@as(usize, @intCast(root_page_id)) >= self.cache.pageCount()) {
                return error.InvalidNode;
            }
            var root = try self.cache.fetch(root_page_id);
            defer root.deinit();
            try self.validateNode(try root.data(), root_page_id, self.snapshot.root_level);
        }

        fn validateNode(self: *const Self, bytes: []const u8, page_id: PhysicalPageId, level: u16) Error!void {
            const header = try self.headerConst(bytes);
            if (!std.mem.eql(u8, &header.magic, node_magic) or
                header.header_size.get() != @sizeOf(NodeHeader) or
                header.reserved.get() != 0 or
                header.self_pid.get() != page_id)
            {
                return error.InvalidNode;
            }
            if (header.version.get() != node_version) {
                return error.UnsupportedNodeVersion;
            }
            if (header.level.get() != level) {
                return error.NodeLevelMismatch;
            }
            _ = try self.slotsConst(bytes);
        }

        fn headerConst(_: *const Self, bytes: []const u8) Error!*const NodeHeader {
            if (bytes.len < @sizeOf(NodeHeader)) {
                return error.NodeTooSmall;
            }
            return @ptrCast(bytes.ptr);
        }

        fn headerMut(_: *const Self, bytes: []u8) Error!*NodeHeader {
            if (bytes.len < @sizeOf(NodeHeader)) {
                return error.NodeTooSmall;
            }
            return @ptrCast(bytes.ptr);
        }

        fn slotsConst(_: *const Self, bytes: []const u8) Error![]const PackedPhysicalPageId {
            if (bytes.len < @sizeOf(NodeHeader) + @sizeOf(PackedPhysicalPageId) * 2) {
                return error.NodeTooSmall;
            }
            return std.mem.bytesAsSlice(
                PackedPhysicalPageId,
                bytes[@sizeOf(NodeHeader)..],
            );
        }

        fn slotsMut(_: *const Self, bytes: []u8) Error![]PackedPhysicalPageId {
            if (bytes.len < @sizeOf(NodeHeader) + @sizeOf(PackedPhysicalPageId) * 2) {
                return error.NodeTooSmall;
            }
            return std.mem.bytesAsSlice(
                PackedPhysicalPageId,
                bytes[@sizeOf(NodeHeader)..],
            );
        }

        fn requiredRootLevel(self: *const Self, virtual_page_id: VirtualPageIdT) Error!u16 {
            var capacity = self.slotCount();
            var level: u16 = 0;
            const page_id = @as(usize, @intCast(virtual_page_id));
            while (page_id >= capacity) {
                const multiplied = @mulWithOverflow(capacity, self.slotCount());
                if (multiplied[1] != 0 or level == std.math.maxInt(u16)) {
                    return error.PageIdExhausted;
                }
                capacity = multiplied[0];
                level += 1;
            }
            return level;
        }

        fn digit(self: *const Self, virtual_page_id: VirtualPageIdT, level: u16) usize {
            var value = @as(usize, @intCast(virtual_page_id));
            var remaining = level;
            while (remaining != 0) : (remaining -= 1) {
                value /= self.slotCount();
            }
            return value % self.slotCount();
        }

        fn slotCount(self: *const Self) usize {
            return (self.cache.pageSize() - @sizeOf(NodeHeader)) / @sizeOf(PackedPhysicalPageId);
        }

        fn nextVirtualPageId(self: *const Self) Error!VirtualPageIdT {
            if (self.snapshot.next_virtual_page_id == std.math.maxInt(VirtualPageIdT)) {
                return error.PageIdExhausted;
            }
            return self.snapshot.next_virtual_page_id;
        }

        fn requireActive(self: *const Self) Error!void {
            if (!self.batch_active or !self.cache.transactionActive()) {
                return error.TransactionInactive;
            }
        }

        comptime {
            virtual_page_map_contract.assertVirtualPageMap(Self);
        }
    };
}
