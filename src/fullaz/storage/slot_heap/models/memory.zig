const std = @import("std");
const interfaces = @import("interfaces.zig");

pub const Settings = struct {
    key_size: usize,
    maximum_value_size: usize,
    leaf_capacity_bytes: usize = 4096,
    inode_capacity: usize = 32,
    max_levels: usize = 64,
};

pub fn Memory(
    comptime cmp: anytype,
    comptime CompareContextT: type,
) type {
    const CompareReturn = @typeInfo(@TypeOf(cmp)).@"fn".return_type orelse
        @compileError("slot-heap comparator must have a return type");
    comptime {
        if (CompareReturn != std.math.Order) {
            @compileError("slot-heap comparator must return std.math.Order");
        }
    }

    const NodeId = usize;
    const SlotId = u16;
    const Count = u64;
    const Space = usize;
    const Location = struct {
        page_id: NodeId,
        slot_id: SlotId,
    };
    const ErrorSet = std.mem.Allocator.Error ||
        error{
            BadKeyLength,
            ChildNotFound,
            CountOverflow,
            EmptySet,
            InvalidId,
            InvalidSettings,
            MaxDepth,
            NodeFull,
            OutOfBounds,
            ValueTooLarge,
            WrongNodeKind,
        };

    const LeafEntry = struct {
        key: []u8,
        value: []u8,

        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.value);
            allocator.free(self.key);
        }
    };

    const InodeEntry = struct {
        key: []u8,
        child_pid: NodeId,
        leaf_top: Location,

        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.key);
        }
    };

    const Context = struct {
        allocator: std.mem.Allocator,
        compare_context: CompareContextT,
        settings: Settings,

        fn compare(self: *const @This(), left: []const u8, right: []const u8) ErrorSet!std.math.Order {
            return cmp(self.compare_context, left, right);
        }
    };

    const LeafContainer = struct {
        entries: std.ArrayList(LeafEntry) = .empty,
        parent: ?NodeId = null,
        used_bytes: usize = 0,
        space_registered: bool = false,

        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            for (self.entries.items) |*entry| {
                entry.deinit(allocator);
            }
            self.entries.deinit(allocator);
        }
    };

    const InodeContainer = struct {
        entries: std.ArrayList(InodeEntry) = .empty,
        parent: ?NodeId = null,
        level: usize,
        available_prev: ?NodeId = null,
        available_next: ?NodeId = null,
        available_linked: bool = false,

        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            for (self.entries.items) |*entry| {
                entry.deinit(allocator);
            }
            self.entries.deinit(allocator);
        }
    };

    const LeafImpl = struct {
        const Self = @This();
        pub const Error = ErrorSet;

        pid: NodeId,
        container: *LeafContainer,
        ctx: *Context,

        pub fn id(self: *const Self) NodeId {
            return self.pid;
        }

        pub fn take(self: *Self) Error!Self {
            const copy = self.*;
            self.* = undefined;
            return copy;
        }

        pub fn size(self: *const Self) Error!usize {
            return self.container.entries.items.len;
        }

        pub fn getParent(self: *const Self) Error!?NodeId {
            return self.container.parent;
        }

        pub fn setParent(self: *Self, parent: ?NodeId) Error!void {
            self.container.parent = parent;
        }

        pub fn getKey(self: *const Self, index: usize) Error![]const u8 {
            if (index >= self.container.entries.items.len) {
                return Error.OutOfBounds;
            }
            return self.container.entries.items[index].key;
        }

        pub fn getValue(self: *const Self, index: usize) Error![]const u8 {
            if (index >= self.container.entries.items.len) {
                return Error.OutOfBounds;
            }
            return self.container.entries.items[index].value;
        }

        pub fn canPush(self: *const Self, key: []const u8, value: []const u8) Error!bool {
            const required = try self.requiredSpace(key, value);
            return required <= self.ctx.settings.leaf_capacity_bytes - self.container.used_bytes;
        }

        pub fn push(self: *Self, key: []const u8, value: []const u8) Error!interfaces.WinnerChange {
            const required = try self.requiredSpace(key, value);
            if (required > self.ctx.settings.leaf_capacity_bytes - self.container.used_bytes) {
                return Error.NodeFull;
            }

            const owned_key = try self.ctx.allocator.dupe(u8, key);
            errdefer self.ctx.allocator.free(owned_key);
            const owned_value = try self.ctx.allocator.dupe(u8, value);
            errdefer self.ctx.allocator.free(owned_value);
            try self.container.entries.append(self.ctx.allocator, .{
                .key = owned_key,
                .value = owned_value,
            });
            self.container.used_bytes += required;

            const final_index = try self.siftUp(self.container.entries.items.len - 1);
            return if (final_index == 0) .changed else .unchanged;
        }

        pub fn popTop(self: *Self) Error!void {
            const count = self.container.entries.items.len;
            if (count == 0) {
                return Error.EmptySet;
            }
            if (count > 1) {
                std.mem.swap(LeafEntry, &self.container.entries.items[0], &self.container.entries.items[count - 1]);
            }
            var removed = self.container.entries.pop().?;
            self.container.used_bytes -= try self.entrySpace(removed.value.len);
            removed.deinit(self.ctx.allocator);
            if (self.container.entries.items.len > 1) {
                _ = try self.siftDown(0);
            }
        }

        pub fn availableAfterCompact(self: *const Self) Error!Space {
            return self.ctx.settings.leaf_capacity_bytes - self.container.used_bytes;
        }

        pub fn usedBytes(self: *const Self) Error!usize {
            return self.container.used_bytes;
        }

        pub fn capacityBytes(self: *const Self) Error!usize {
            return self.ctx.settings.leaf_capacity_bytes;
        }

        fn requiredSpace(self: *const Self, key: []const u8, value: []const u8) Error!usize {
            if (key.len != self.ctx.settings.key_size) {
                return Error.BadKeyLength;
            }
            if (value.len > self.ctx.settings.maximum_value_size) {
                return Error.ValueTooLarge;
            }
            return self.entrySpace(value.len);
        }

        fn entrySpace(self: *const Self, value_len: usize) Error!usize {
            const content = std.math.add(usize, self.ctx.settings.key_size, value_len) catch {
                return Error.ValueTooLarge;
            };
            return std.math.add(usize, content, 4) catch Error.ValueTooLarge;
        }

        fn siftUp(self: *Self, start: usize) Error!usize {
            var index = start;
            while (index > 0) {
                const parent = (index - 1) / 2;
                if ((try self.ctx.compare(
                    self.container.entries.items[index].key,
                    self.container.entries.items[parent].key,
                )) != .lt) {
                    break;
                }
                std.mem.swap(
                    LeafEntry,
                    &self.container.entries.items[index],
                    &self.container.entries.items[parent],
                );
                index = parent;
            }
            return index;
        }

        fn siftDown(self: *Self, start: usize) Error!usize {
            var index = start;
            while (true) {
                const left = index * 2 + 1;
                if (left >= self.container.entries.items.len) {
                    break;
                }
                const right = left + 1;
                var best = left;
                if (right < self.container.entries.items.len and
                    (try self.ctx.compare(
                        self.container.entries.items[right].key,
                        self.container.entries.items[left].key,
                    )) == .lt)
                {
                    best = right;
                }
                if ((try self.ctx.compare(
                    self.container.entries.items[best].key,
                    self.container.entries.items[index].key,
                )) != .lt) {
                    break;
                }
                std.mem.swap(
                    LeafEntry,
                    &self.container.entries.items[index],
                    &self.container.entries.items[best],
                );
                index = best;
            }
            return index;
        }
    };

    const InodeImpl = struct {
        const Self = @This();
        pub const Error = ErrorSet;

        pid: NodeId,
        container: *InodeContainer,
        ctx: *Context,

        pub fn id(self: *const Self) NodeId {
            return self.pid;
        }

        pub fn take(self: *Self) Error!Self {
            const copy = self.*;
            self.* = undefined;
            return copy;
        }

        pub fn size(self: *const Self) Error!usize {
            return self.container.entries.items.len;
        }

        pub fn capacity(self: *const Self) Error!usize {
            return self.ctx.settings.inode_capacity;
        }

        pub fn getLevel(self: *const Self) Error!usize {
            return self.container.level;
        }

        pub fn getParent(self: *const Self) Error!?NodeId {
            return self.container.parent;
        }

        pub fn setParent(self: *Self, parent: ?NodeId) Error!void {
            self.container.parent = parent;
        }

        pub fn getAvailablePrev(self: *const Self) Error!?NodeId {
            return self.container.available_prev;
        }

        pub fn setAvailablePrev(self: *Self, previous: ?NodeId) Error!void {
            self.container.available_prev = previous;
        }

        pub fn getAvailableNext(self: *const Self) Error!?NodeId {
            return self.container.available_next;
        }

        pub fn setAvailableNext(self: *Self, next: ?NodeId) Error!void {
            self.container.available_next = next;
        }

        pub fn isAvailableLinked(self: *const Self) Error!bool {
            return self.container.available_linked;
        }

        pub fn setAvailableLinked(self: *Self, linked: bool) Error!void {
            self.container.available_linked = linked;
        }

        pub fn findChild(self: *const Self, child_pid: NodeId) Error!?usize {
            for (self.container.entries.items, 0..) |entry, index| {
                if (entry.child_pid == child_pid) {
                    return index;
                }
            }
            return null;
        }

        pub fn getKey(self: *const Self, index: usize) Error![]const u8 {
            if (index >= self.container.entries.items.len) {
                return Error.OutOfBounds;
            }
            return self.container.entries.items[index].key;
        }

        pub fn getChild(self: *const Self, index: usize) Error!NodeId {
            if (index >= self.container.entries.items.len) {
                return Error.OutOfBounds;
            }
            return self.container.entries.items[index].child_pid;
        }

        pub fn getWinner(self: *const Self, index: usize) Error!Location {
            if (index >= self.container.entries.items.len) {
                return Error.OutOfBounds;
            }
            return self.container.entries.items[index].leaf_top;
        }

        pub fn insertChild(
            self: *Self,
            key: []const u8,
            child_pid: NodeId,
            leaf_top: Location,
        ) Error!interfaces.WinnerChange {
            if (self.container.entries.items.len >= self.ctx.settings.inode_capacity) {
                return Error.NodeFull;
            }
            try self.validateKey(key);
            const owned_key = try self.ctx.allocator.dupe(u8, key);
            errdefer self.ctx.allocator.free(owned_key);
            try self.container.entries.append(self.ctx.allocator, .{
                .key = owned_key,
                .child_pid = child_pid,
                .leaf_top = leaf_top,
            });
            const final_index = try self.siftUp(self.container.entries.items.len - 1);
            return if (final_index == 0) .changed else .unchanged;
        }

        pub fn updateChild(
            self: *Self,
            index: usize,
            key: []const u8,
            leaf_top: Location,
        ) Error!interfaces.WinnerChange {
            if (index >= self.container.entries.items.len) {
                return Error.OutOfBounds;
            }
            try self.validateKey(key);
            const order = try self.ctx.compare(key, self.container.entries.items[index].key);
            if (key.ptr != self.container.entries.items[index].key.ptr) {
                std.mem.copyForwards(u8, self.container.entries.items[index].key, key);
            }
            self.container.entries.items[index].leaf_top = leaf_top;

            const final_index = switch (order) {
                .lt => try self.siftUp(index),
                .gt => try self.siftDown(index),
                .eq => index,
            };
            return if (index == 0 or final_index == 0) .changed else .unchanged;
        }

        pub fn removeChild(self: *Self, index: usize) Error!interfaces.WinnerChange {
            const count = self.container.entries.items.len;
            if (index >= count) {
                return Error.OutOfBounds;
            }
            if (index != count - 1) {
                std.mem.swap(
                    InodeEntry,
                    &self.container.entries.items[index],
                    &self.container.entries.items[count - 1],
                );
            }
            var removed = self.container.entries.pop().?;
            removed.deinit(self.ctx.allocator);
            if (index >= self.container.entries.items.len) {
                return if (index == 0) .changed else .unchanged;
            }
            const final_index = try self.fixAt(index);
            return if (index == 0 or final_index == 0) .changed else .unchanged;
        }

        fn validateKey(self: *const Self, key: []const u8) Error!void {
            if (key.len != self.ctx.settings.key_size) {
                return Error.BadKeyLength;
            }
        }

        fn fixAt(self: *Self, index: usize) Error!usize {
            if (index > 0) {
                const parent = (index - 1) / 2;
                if ((try self.ctx.compare(
                    self.container.entries.items[index].key,
                    self.container.entries.items[parent].key,
                )) == .lt) {
                    return self.siftUp(index);
                }
            }
            return self.siftDown(index);
        }

        fn siftUp(self: *Self, start: usize) Error!usize {
            var index = start;
            while (index > 0) {
                const parent = (index - 1) / 2;
                if ((try self.ctx.compare(
                    self.container.entries.items[index].key,
                    self.container.entries.items[parent].key,
                )) != .lt) {
                    break;
                }
                std.mem.swap(
                    InodeEntry,
                    &self.container.entries.items[index],
                    &self.container.entries.items[parent],
                );
                index = parent;
            }
            return index;
        }

        fn siftDown(self: *Self, start: usize) Error!usize {
            var index = start;
            while (true) {
                const left = index * 2 + 1;
                if (left >= self.container.entries.items.len) {
                    break;
                }
                const right = left + 1;
                var best = left;
                if (right < self.container.entries.items.len and
                    (try self.ctx.compare(
                        self.container.entries.items[right].key,
                        self.container.entries.items[left].key,
                    )) == .lt)
                {
                    best = right;
                }
                if ((try self.ctx.compare(
                    self.container.entries.items[best].key,
                    self.container.entries.items[index].key,
                )) != .lt) {
                    break;
                }
                std.mem.swap(
                    InodeEntry,
                    &self.container.entries.items[index],
                    &self.container.entries.items[best],
                );
                index = best;
            }
            return index;
        }
    };

    const NodeVariant = union(enum) {
        leaf: *LeafContainer,
        inode: *InodeContainer,
    };

    const AccessorImpl = struct {
        const Self = @This();
        pub const Error = ErrorSet;

        ctx: Context,
        nodes: std.ArrayList(?NodeVariant) = .empty,
        root: ?NodeId = null,
        cached_top: ?Location = null,
        entries_count: Count = 0,
        available_inode_heads: []?NodeId,

        fn init(
            allocator: std.mem.Allocator,
            compare_context: CompareContextT,
            settings: Settings,
        ) Error!Self {
            const minimum_leaf_size = std.math.add(usize, settings.key_size, 4) catch {
                return Error.InvalidSettings;
            };
            if (settings.key_size == 0 or settings.inode_capacity < 2 or
                settings.max_levels == 0 or settings.leaf_capacity_bytes < minimum_leaf_size)
            {
                return Error.InvalidSettings;
            }
            const heads = try allocator.alloc(?NodeId, settings.max_levels);
            @memset(heads, null);
            return .{
                .ctx = .{
                    .allocator = allocator,
                    .compare_context = compare_context,
                    .settings = settings,
                },
                .available_inode_heads = heads,
            };
        }

        fn deinit(self: *Self) void {
            for (self.nodes.items) |maybe_node| {
                if (maybe_node) |stored_node| {
                    switch (stored_node) {
                        .leaf => |leaf| {
                            leaf.deinit(self.ctx.allocator);
                            self.ctx.allocator.destroy(leaf);
                        },
                        .inode => |inode| {
                            inode.deinit(self.ctx.allocator);
                            self.ctx.allocator.destroy(inode);
                        },
                    }
                }
            }
            self.nodes.deinit(self.ctx.allocator);
            self.ctx.allocator.free(self.available_inode_heads);
        }

        pub fn getRoot(self: *const Self) ?NodeId {
            return self.root;
        }

        pub fn setRoot(self: *Self, root: ?NodeId) Error!void {
            self.root = root;
        }

        pub fn getCachedTop(self: *const Self) ?Location {
            return self.cached_top;
        }

        pub fn setCachedTop(self: *Self, top: ?Location) Error!void {
            self.cached_top = top;
        }

        pub fn getAvailableInode(self: *const Self, level: usize) Error!?NodeId {
            if (level >= self.available_inode_heads.len) {
                return Error.MaxDepth;
            }
            return self.available_inode_heads[level];
        }

        pub fn setAvailableInode(self: *Self, level: usize, inode: ?NodeId) Error!void {
            if (level >= self.available_inode_heads.len) {
                return Error.MaxDepth;
            }
            self.available_inode_heads[level] = inode;
        }

        pub fn createLeaf(self: *Self) Error!LeafImpl {
            const pid = self.nodes.items.len;
            const container = try self.ctx.allocator.create(LeafContainer);
            errdefer self.ctx.allocator.destroy(container);
            container.* = .{};
            try self.nodes.append(self.ctx.allocator, .{ .leaf = container });
            return .{ .pid = pid, .container = container, .ctx = &self.ctx };
        }

        pub fn createInode(self: *Self, level: usize) Error!InodeImpl {
            if (level == 0 or level >= self.available_inode_heads.len) {
                return Error.MaxDepth;
            }
            const pid = self.nodes.items.len;
            const container = try self.ctx.allocator.create(InodeContainer);
            errdefer self.ctx.allocator.destroy(container);
            container.* = .{ .level = level };
            try self.nodes.append(self.ctx.allocator, .{ .inode = container });
            return .{ .pid = pid, .container = container, .ctx = &self.ctx };
        }

        pub fn loadLeaf(self: *Self, pid: NodeId) Error!?LeafImpl {
            const stored_node = try self.getNode(pid);
            return switch (stored_node) {
                .leaf => |leaf| .{
                    .pid = pid,
                    .container = leaf,
                    .ctx = &self.ctx,
                },
                .inode => null,
            };
        }

        pub fn loadInode(self: *Self, pid: NodeId) Error!?InodeImpl {
            const stored_node = try self.getNode(pid);
            return switch (stored_node) {
                .inode => |inode| .{
                    .pid = pid,
                    .container = inode,
                    .ctx = &self.ctx,
                },
                .leaf => null,
            };
        }

        pub fn deinitLeaf(_: *Self, _: ?LeafImpl) void {}

        pub fn deinitInode(_: *Self, _: ?InodeImpl) void {}

        pub fn isLeafId(self: *Self, pid: NodeId) Error!bool {
            return switch (try self.getNode(pid)) {
                .leaf => true,
                .inode => false,
            };
        }

        pub fn destroy(self: *Self, pid: NodeId) Error!void {
            const stored_node = try self.getNode(pid);
            switch (stored_node) {
                .leaf => |leaf| {
                    leaf.deinit(self.ctx.allocator);
                    self.ctx.allocator.destroy(leaf);
                },
                .inode => |inode| {
                    inode.deinit(self.ctx.allocator);
                    self.ctx.allocator.destroy(inode);
                },
            }
            self.nodes.items[pid] = null;
        }

        pub fn findLeaf(self: *Self, required: Space) Error!?NodeId {
            var best: ?NodeId = null;
            var best_available: usize = std.math.maxInt(usize);
            for (self.nodes.items, 0..) |maybe_node, pid| {
                const stored_node = maybe_node orelse continue;
                switch (stored_node) {
                    .leaf => |leaf| {
                        if (!leaf.space_registered) {
                            continue;
                        }
                        const available = self.ctx.settings.leaf_capacity_bytes - leaf.used_bytes;
                        if (available >= required and available < best_available) {
                            best = pid;
                            best_available = available;
                        }
                    },
                    .inode => {},
                }
            }
            return best;
        }

        pub fn addLeafSpace(self: *Self, pid: NodeId, _: Space) Error!void {
            const leaf = (try self.loadLeaf(pid)) orelse return Error.WrongNodeKind;
            defer self.deinitLeaf(leaf);
            leaf.container.space_registered = true;
        }

        pub fn updateLeafSpace(self: *Self, pid: NodeId, _: Space) Error!void {
            const leaf = (try self.loadLeaf(pid)) orelse return Error.WrongNodeKind;
            defer self.deinitLeaf(leaf);
            if (!leaf.container.space_registered) {
                return Error.InvalidId;
            }
        }

        pub fn removeLeafSpace(self: *Self, pid: NodeId) Error!void {
            var leaf = (try self.loadLeaf(pid)) orelse return Error.WrongNodeKind;
            defer self.deinitLeaf(leaf);
            leaf.container.space_registered = false;
        }

        fn getNode(self: *Self, pid: NodeId) Error!NodeVariant {
            if (pid >= self.nodes.items.len) {
                return Error.InvalidId;
            }
            return self.nodes.items[pid] orelse Error.InvalidId;
        }
    };

    return struct {
        const Self = @This();

        pub const NodeIdType = NodeId;
        pub const SlotIdType = SlotId;
        pub const LocationType = Location;
        pub const CountType = Count;
        pub const SpaceType = Space;
        pub const KeyInType = []const u8;
        pub const KeyOutType = []const u8;
        pub const ValueInType = []const u8;
        pub const ValueOutType = []const u8;
        pub const LeafType = LeafImpl;
        pub const InodeType = InodeImpl;
        pub const AccessorType = AccessorImpl;
        pub const Error = ErrorSet;

        accessor_state: AccessorType,

        pub fn init(
            allocator: std.mem.Allocator,
            compare_context: CompareContextT,
            settings: Settings,
        ) Error!Self {
            return .{
                .accessor_state = try AccessorType.init(
                    allocator,
                    compare_context,
                    settings,
                ),
            };
        }

        pub fn deinit(self: *Self) void {
            self.accessor_state.deinit();
        }

        pub fn accessor(self: *Self) *AccessorType {
            return &self.accessor_state;
        }

        pub fn compareKeys(self: *const Self, left: KeyOutType, right: KeyOutType) Error!std.math.Order {
            return self.accessor_state.ctx.compare(left, right);
        }

        pub fn keyOutAsIn(_: *const Self, key: KeyOutType) KeyInType {
            return key;
        }

        pub fn requiredLeafSpace(self: *const Self, key: KeyInType, value: ValueInType) Error!Space {
            if (key.len != self.accessor_state.ctx.settings.key_size) {
                return Error.BadKeyLength;
            }
            if (value.len > self.accessor_state.ctx.settings.maximum_value_size) {
                return Error.ValueTooLarge;
            }
            const content = std.math.add(usize, key.len, value.len) catch {
                return Error.ValueTooLarge;
            };
            return std.math.add(usize, content, 4) catch Error.ValueTooLarge;
        }

        pub fn incrementEntriesCount(self: *Self) Error!void {
            self.accessor_state.entries_count = std.math.add(
                Count,
                self.accessor_state.entries_count,
                1,
            ) catch return Error.CountOverflow;
        }

        pub fn decrementEntriesCount(self: *Self) Error!void {
            if (self.accessor_state.entries_count == 0) {
                return Error.CountOverflow;
            }
            self.accessor_state.entries_count -= 1;
        }

        pub fn getEntriesCount(self: *const Self) Error!Count {
            return self.accessor_state.entries_count;
        }
    };
}
