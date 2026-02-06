const std = @import("std");
const errors = @import("../../core/errors.zig");

pub fn Model(comptime T: type, comptime MaximumElements: usize) type {
    const Pid = usize;
    const Weight = usize;

    comptime {
        if (MaximumElements < 4) {
            @compileError("MaximumElements must be at least 4 to ensure proper tree balancing.");
        }
    }

    const NodePosition = struct {
        pos: usize,
        diff: Weight,
        accumulated: Weight,
    };

    const Value = std.ArrayList(T);

    const Context = struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
            };
        }
    };

    const ValueViewImpl = struct {
        const Self = @This();
        const Error = error{};

        value: []const T,

        pub fn init(value: []const T) Error!Self {
            return .{
                .value = value,
            };
        }

        pub fn deinit(_: *Self) void {}

        pub fn weight(self: *const Self) Error!Weight {
            return @as(Weight, @intCast(self.value.len));
        }

        pub fn get(self: *const Self) Error![]const T {
            return self.value;
        }
    };

    const ValuePolicyImpl = struct {
        const Self = @This();
        const Error = std.mem.Allocator.Error;

        const ValueUnion = union(enum) {
            owned: Value,
            borrowed: *Value,
        };

        value: ValueUnion,
        ctx: *Context = undefined,

        pub fn init(value: *Value, ctx: *Context) Self {
            return .{
                .value = .{ .borrowed = value },
                .ctx = ctx,
            };
        }

        pub fn initOwned(value: Value, ctx: *Context) Self {
            return .{
                .value = .{ .owned = value },
                .ctx = ctx,
            };
        }

        pub fn splitOfRight(self: *Self, pos: Weight) Error!Self {
            const result_weight = self.weight() - pos;

            var new_value = try std.ArrayList(T).initCapacity(self.ctx.allocator, result_weight);
            errdefer new_value.deinit(self.ctx.allocator);

            const slice = self.asSlice();

            try new_value.appendSlice(self.ctx.allocator, slice[pos..slice.len]);

            self.shrink(pos);

            return Self.initOwned(new_value, self.ctx);
        }

        pub fn splitOfLeft(self: *Self, pos: Weight) Error!Self {
            const result_weight = pos;
            var new_value = try std.ArrayList(T).initCapacity(self.ctx.allocator, result_weight);
            errdefer new_value.deinit(self.ctx.allocator);

            var slice = self.asSliceMut();

            try new_value.appendSlice(self.ctx.allocator, slice[0..pos]);

            const tail_values = slice[pos..slice.len];
            const head_place = slice[0..tail_values.len];
            @memmove(head_place, tail_values);
            self.shrink(tail_values.len);

            return Self.initOwned(new_value, self.ctx);
        }

        pub fn deinit(self: *Self) void {
            switch (self.value) {
                .borrowed => {},
                .owned => |*owned_val| {
                    owned_val.deinit(self.ctx.allocator);
                },
            }
        }

        pub fn weight(self: *const Self) Weight {
            switch (self.value) {
                .owned => |*owned_val| return @as(Weight, @intCast(owned_val.items.len)),
                .borrowed => |borrowed_val| return @as(Weight, @intCast(borrowed_val.items.len)),
            }
        }

        pub fn asSlice(self: *const Self) []const T {
            switch (self.value) {
                .owned => |*owned_val| return owned_val.items[0..owned_val.items.len],
                .borrowed => |borrowed_val| return borrowed_val.items[0..borrowed_val.items.len],
            }
        }

        pub fn get(self: *const Self) Error![]const T {
            return self.asSlice();
        }

        pub fn asSliceMut(self: *Self) []T {
            switch (self.value) {
                .owned => |*owned_val| return owned_val.items[0..owned_val.items.len],
                .borrowed => |borrowed_val| return borrowed_val.items[0..borrowed_val.items.len],
            }
        }

        fn shrink(self: *Self, new_size: usize) void {
            switch (self.value) {
                .owned => |*owned_val| {
                    owned_val.shrinkAndFree(self.ctx.allocator, new_size);
                },
                .borrowed => |borrowed_val| {
                    borrowed_val.shrinkAndFree(self.ctx.allocator, new_size);
                },
            }
        }
    };

    const InodeContainer = struct {
        const Self = @This();
        const Error = std.mem.Allocator.Error;

        const WeightChild = struct {
            weight: Weight,
            pid: Pid,
        };

        values: std.ArrayList(WeightChild),
        total_weight: Weight = 0,
        parent: ?Pid = null,

        fn init(allocator: std.mem.Allocator) Error!Self {
            return .{
                .values = try std.ArrayList(WeightChild).initCapacity(allocator, 0),
            };
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.values.deinit(allocator);
        }
    };

    const LeafContainer = struct {
        const Self = @This();
        const Error = std.mem.Allocator.Error;

        values: std.ArrayList(Value),
        parent: ?Pid = null,
        prev: ?Pid = null,
        next: ?Pid = null,

        fn init(allocator: std.mem.Allocator) Error!Self {
            return .{
                .values = try std.ArrayList(Value).initCapacity(allocator, 0),
                .parent = null,
                .prev = null,
                .next = null,
            };
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (self.values.items) |*item| {
                item.deinit(allocator);
            }
            self.values.deinit(allocator);
        }
    };

    const InodeImpl = struct {
        const Self = @This();
        const Error = errors.HandleError ||
            errors.IndexError ||
            errors.BptError ||
            std.mem.Allocator.Error;

        pid: Pid,
        inode: *InodeContainer = undefined,
        ctx: *Context = undefined,

        fn init(inode: *InodeContainer, ctx: *Context, pid: Pid) Self {
            return .{
                .pid = pid,
                .inode = inode,
                .ctx = ctx,
            };
        }

        pub fn size(self: *const Self) Error!usize {
            return self.inode.values.items.len;
        }

        pub fn capacity(_: *const Self) Error!usize {
            return MaximumElements;
        }

        pub fn isUnderflowed(self: *const Self) Error!bool {
            const sz = try self.size();
            const cap = try self.capacity();
            return sz < (cap / 2);
        }

        pub fn totalWeight(self: *const Self) Error!Weight {
            return self.inode.total_weight;
        }

        pub fn canInsertAt(self: *const Self, _: usize, _: Weight) Error!bool {
            const sz = try self.size();
            const cap = try self.capacity();
            const current_available = cap - sz;
            return current_available > 0;
        }

        pub fn id(self: *const Self) Pid {
            return self.pid;
        }

        pub fn getParent(self: *const Self) Error!?Pid {
            return self.inode.parent;
        }

        pub fn setParent(self: *Self, parent: ?Pid) Error!void {
            self.inode.parent = parent;
        }

        pub fn insertChild(self: *Self, pos: usize, child: Pid, weight: Weight) Error!void {
            if (pos > self.inode.values.items.len) {
                return Error.OutOfBounds;
            }
            if (self.inode.values.items.len >= MaximumElements) {
                return Error.NodeFull;
            }

            try self.inode.values.insert(self.ctx.allocator, pos, .{
                .weight = weight,
                .pid = child,
            });
            self.inode.total_weight += weight;
        }

        pub fn removeAt(self: *Self, pos: usize) Error!void {
            if (pos >= self.inode.values.items.len) {
                return Error.OutOfBounds;
            }
            const removed = self.inode.values.orderedRemove(pos);
            self.inode.total_weight -= removed.weight;
        }

        pub fn getChild(self: *const Self, pos: usize) Error!Pid {
            if (pos >= self.inode.values.items.len) {
                return Error.OutOfBounds;
            }
            return self.inode.values.items[pos].pid;
        }

        pub fn updateChild(self: *Self, pos: usize, new_child: Pid) Error!void {
            if (pos >= self.inode.values.items.len) {
                return Error.OutOfBounds;
            }
            self.inode.values.items[pos].pid = new_child;
        }

        pub fn getWeight(self: *const Self, pos: usize) Error!Weight {
            if (pos >= self.inode.values.items.len) {
                return Error.OutOfBounds;
            }
            return self.inode.values.items[pos].weight;
        }

        pub fn updateWeight(self: *Self, pos: usize, new_weight: Weight) Error!void {
            if (pos >= self.inode.values.items.len) {
                return Error.OutOfBounds;
            }
            const old_weight = self.inode.values.items[pos].weight;
            self.inode.values.items[pos].weight = new_weight;
            self.inode.total_weight = self.inode.total_weight - old_weight + new_weight;
        }

        pub fn selectPos(self: *const Self, weight: Weight) Error!NodePosition {
            if (self.inode.values.items.len == 0) {
                return .{
                    .pos = 0,
                    .diff = weight,
                    .accumulated = 0,
                };
            }
            const last_idx = self.inode.values.items.len - 1;
            var accumulated: Weight = 0;
            for (0..last_idx) |idx| {
                const current = self.inode.values.items[idx].weight;
                accumulated += current;
                if (accumulated > weight) {
                    const diff = accumulated - weight;
                    const current_diff = (current - diff);
                    return .{
                        .pos = idx,
                        .diff = current_diff,
                        .accumulated = accumulated - current,
                    };
                } else if (accumulated == weight) {
                    return .{
                        .pos = idx + 1,
                        .diff = 0,
                        .accumulated = accumulated,
                    };
                }
            }
            return .{
                .pos = last_idx,
                .diff = weight - accumulated,
                .accumulated = accumulated,
            };
        }
    };

    const LeafImpl = struct {
        const Self = @This();
        const PidType = Pid;
        const Error = errors.HandleError ||
            errors.BptError ||
            errors.IndexError ||
            std.mem.Allocator.Error;

        const MaximumCapacity = MaximumElements;

        pid: Pid,
        leaf: *LeafContainer = undefined,
        ctx: *Context = undefined,

        fn init(leaf: *LeafContainer, ctx: *Context, pid: Pid) Self {
            return .{
                .pid = pid,
                .leaf = leaf,
                .ctx = ctx,
            };
        }

        pub fn size(self: *const Self) Error!usize {
            return self.leaf.values.items.len;
        }

        pub fn capacity(_: *const Self) Error!usize {
            return MaximumElements;
        }

        pub fn totalWeight(self: *const Self) Error!Weight {
            var total: Weight = 0;
            for (self.leaf.values.items) |*item| {
                total += item.items.len;
            }
            return total;
        }

        pub fn isUnderflowed(self: *const Self) Error!bool {
            const sz = try self.size();
            const cap = try self.capacity();
            return sz < (cap / 2);
        }

        pub fn id(self: *const Self) Pid {
            return self.pid;
        }

        pub fn getNext(self: *const Self) Error!?Pid {
            return self.leaf.next;
        }

        pub fn getPrev(self: *const Self) Error!?Pid {
            return self.leaf.prev;
        }

        pub fn getPare(self: *const Self) Error!?Pid {
            return self.leaf.parent;
        }

        pub fn setNext(self: *Self, next: ?Pid) Error!void {
            self.leaf.next = next;
        }

        pub fn setPrev(self: *Self, prev: ?Pid) Error!void {
            self.leaf.prev = prev;
        }

        pub fn getParent(self: *const Self) Error!?Pid {
            return self.leaf.parent;
        }

        pub fn setParent(self: *Self, parent: ?Pid) Error!void {
            self.leaf.parent = parent;
        }

        pub fn getValue(self: *const Self, pos: usize) Error!ValueViewImpl {
            try self.checkPos(pos);
            return ValueViewImpl.init(self.leaf.values.items[pos].items);
        }

        pub fn canInsertWeight(self: *const Self, where: Weight) Error!bool {
            const current_weight = try self.size();
            const current_available = MaximumCapacity - current_weight;
            if (current_available == 0) {
                return false;
            }
            const pos = try self.selectPos(where);
            if (pos.diff > 0) {
                return current_available > 1;
            }
            return true;
        }

        pub fn insertWeight(self: *Self, where: Weight, val: []const T) Error!void {
            const pos = try self.selectPos(where);

            if (pos.diff == 0) {
                try self.insertAt(pos.pos, val);
            } else {
                var policy = ValuePolicyImpl.init(&self.leaf.values.items[pos.pos], self.ctx);
                defer policy.deinit();
                var new_policy = try policy.splitOfRight(pos.diff);
                defer new_policy.deinit();
                try self.insertAt(pos.pos + 1, new_policy.asSlice());
                try self.insertAt(pos.pos + 1, val);
            }
        }

        pub fn insertAt(self: *Self, pos: usize, val: []const T) Error!void {
            if (pos > self.leaf.values.items.len) {
                return Error.OutOfBounds;
            }
            if (self.leaf.values.items.len >= MaximumCapacity) {
                return Error.NodeFull;
            }

            var new_val = try std.ArrayList(T).initCapacity(self.ctx.allocator, val.len);
            errdefer new_val.deinit(self.ctx.allocator);
            try new_val.appendSlice(self.ctx.allocator, val);
            try self.leaf.values.insert(self.ctx.allocator, pos, new_val);
        }

        pub fn removeAt(self: *Self, pos: usize) Error!void {
            try self.checkPos(pos);
            var val = self.leaf.values.orderedRemove(pos);
            val.deinit(self.ctx.allocator);
        }

        pub fn selectPos(self: *const Self, weight: Weight) Error!NodePosition {
            var accumulated: Weight = 0;
            for (self.leaf.values.items, 0..) |*item, idx| {
                const current = item.items.len;
                accumulated += current;
                if (accumulated > weight) {
                    const diff = accumulated - weight;
                    const current_diff = (current - diff);
                    return .{
                        .pos = idx,
                        .diff = current_diff,
                        .accumulated = accumulated - current,
                    };
                }
                if (accumulated == weight) {
                    return .{
                        .pos = idx + 1,
                        .diff = 0,
                        .accumulated = accumulated,
                    };
                }
            }
            return .{
                .pos = self.leaf.values.items.len,
                .diff = 0,
                .accumulated = accumulated,
            };
        }

        fn checkPos(self: *const Self, pos: usize) Error!void {
            if (pos >= self.leaf.values.items.len) {
                return error.OutOfBounds;
            }
        }
    };

    const NodeVariant = union(enum) {
        inode: *InodeContainer,
        leaf: *LeafContainer,
    };

    const AccessorImpl = struct {
        const Self = @This();

        const Error =
            errors.IndexError ||
            errors.PageError ||
            std.mem.Allocator.Error;

        ctx: Context = undefined,
        values: std.ArrayList(?NodeVariant),
        root: ?usize = null,

        fn init(allocator: std.mem.Allocator) Error!Self {
            return .{
                .ctx = Context.init(allocator),
                .values = try std.ArrayList(?NodeVariant).initCapacity(allocator, 0),
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.values.items) |*item| {
                if (item.*) |*item_val| {
                    switch (item_val.*) {
                        .inode => |inode| {
                            inode.deinit(self.ctx.allocator);
                            self.ctx.allocator.destroy(inode);
                        },
                        .leaf => |leaf| {
                            leaf.deinit(self.ctx.allocator);
                            self.ctx.allocator.destroy(leaf);
                        },
                    }
                }
            }
            self.values.deinit(self.ctx.allocator);
        }

        pub fn getRoot(self: *const Self) Error!?Pid {
            return self.root;
        }

        pub fn setRoot(self: *Self, root: ?Pid) Error!void {
            self.root = root;
        }

        pub fn createLeaf(self: *Self) Error!LeafImpl {
            const size = self.values.items.len;
            const new_leaf = try self.ctx.allocator.create(LeafContainer);
            errdefer self.ctx.allocator.destroy(new_leaf);
            new_leaf.* = try LeafContainer.init(self.ctx.allocator);

            try self.values.append(self.ctx.allocator, .{
                .leaf = new_leaf,
            });
            return LeafImpl.init(self.values.items[size].?.leaf, &self.ctx, size);
        }

        pub fn loadLeaf(self: *Self, pid: Pid) Error!LeafImpl {
            if (pid >= self.values.items.len) {
                return Error.OutOfBounds;
            }
            if (self.values.items[pid]) |*node| {
                return switch (node.*) {
                    .leaf => |leaf| LeafImpl.init(leaf, &self.ctx, pid),
                    else => return Error.InvalidId,
                };
            }
            return error.InvalidId;
        }

        pub fn deinitLeaf(_: *Self, leaf: *LeafImpl) void {
            leaf.* = undefined;
        }

        pub fn createInode(self: *Self) Error!InodeImpl {
            const size = self.values.items.len;
            const new_inode = try self.ctx.allocator.create(InodeContainer);
            errdefer self.ctx.allocator.destroy(new_inode);
            new_inode.* = try InodeContainer.init(self.ctx.allocator);

            try self.values.append(self.ctx.allocator, .{
                .inode = new_inode,
            });
            return InodeImpl.init(self.values.items[size].?.inode, &self.ctx, size);
        }

        pub fn loadInode(self: *Self, pid: Pid) Error!InodeImpl {
            if (pid >= self.values.items.len) {
                return Error.OutOfBounds;
            }
            if (self.values.items[pid]) |*node| {
                return switch (node.*) {
                    .inode => |inode| InodeImpl.init(inode, &self.ctx, pid),
                    else => return Error.InvalidId,
                };
            }
            return error.InvalidId;
        }

        pub fn deinitInode(_: *Self, inode: *InodeImpl) void {
            inode.* = undefined;
        }

        pub fn isLeaf(self: *const Self, pid: Pid) Error!bool {
            if (pid >= self.values.items.len) {
                return Error.OutOfBounds;
            }
            return switch (self.values.items[pid].?) {
                .leaf => true,
                .inode => false,
            };
        }
    };

    return struct {
        const Self = @This();
        pub const AccessorType = AccessorImpl;
        pub const ValueType = []const T;
        pub const LeafType = LeafImpl;
        pub const InodeType = InodeImpl;
        //pub const ValuePolicyType = ValuePolicyImpl;
        pub const ValueViewType = ValueViewImpl;
        pub const WeightType = Weight;
        pub const PidType = Pid;
        pub const NodePositionType = NodePosition;

        pub const Error = error{} ||
            AccessorImpl.Error ||
            LeafImpl.Error ||
            InodeImpl.Error ||
            std.mem.Allocator.Error;

        accessor: AccessorImpl,

        pub fn init(allocator: std.mem.Allocator) Error!Self {
            return .{
                .accessor = try AccessorImpl.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.accessor.deinit();
        }

        pub fn getAccessor(self: *Self) *AccessorImpl {
            return &self.accessor;
        }
    };
}
