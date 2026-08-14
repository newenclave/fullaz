const std = @import("std");
const interfaces = @import("../../contracts/interfaces.zig");

const requiresFnSignature = interfaces.requiresFnSignature;
const requiresTypeDeclaration = interfaces.requiresTypeDeclaration;

pub fn assertBox(comptime BoxT: type) void {
    requiresTypeDeclaration(BoxT, "Coord");

    const Coord = BoxT.Coord;

    requiresFnSignature(BoxT, "merged", fn (*const BoxT, *const BoxT) BoxT);
    requiresFnSignature(BoxT, "overlaps", fn (*const BoxT, *const BoxT) bool);
    requiresFnSignature(BoxT, "containsBox", fn (*const BoxT, *const BoxT) bool);
    requiresFnSignature(BoxT, "perimeter", fn (*const BoxT) Coord);
}

pub fn assertFatBox(comptime BoxT: type) void {
    assertBox(BoxT);

    requiresFnSignature(BoxT, "expanded", fn (*const BoxT, BoxT.Coord) BoxT);
}

fn ExactConfig(comptime BoxT: type) type {
    return struct {
        pub const loose_updates = false;

        pub fn makeTreeBox(exact: BoxT) BoxT {
            return exact;
        }
    };
}

fn FatConfig(comptime BoxT: type, comptime margin: BoxT.Coord) type {
    return struct {
        pub const loose_updates = true;

        pub fn makeTreeBox(exact: BoxT) BoxT {
            return exact.expanded(margin);
        }
    };
}

pub fn Tree(comptime BoxT: type, comptime ValueT: type) type {
    return TreeImpl(BoxT, ValueT, ExactConfig(BoxT));
}

pub fn FatTree(comptime BoxT: type, comptime ValueT: type, comptime margin: BoxT.Coord) type {
    comptime assertFatBox(BoxT);
    return TreeImpl(BoxT, ValueT, FatConfig(BoxT, margin));
}

fn TreeImpl(comptime BoxT: type, comptime ValueT: type, comptime ConfigT: type) type {
    comptime {
        assertBox(BoxT);
    }

    const Box = BoxT;
    const Value = ValueT;

    return struct {
        const Self = @This();

        pub const NodeId = struct {
            index: usize,
            generation: u64,

            fn eql(self: NodeId, other: NodeId) bool {
                return self.index == other.index and self.generation == other.generation;
            }
        };
        pub const QueryStack = std.ArrayList(NodeId);
        pub const Error = error{ InvalidNode, WrongNodeKind } || std.mem.Allocator.Error;

        const Node = struct {
            bbox: Box,
            exact_bbox: Box,
            parent: ?NodeId = null,
            left: ?NodeId = null,
            right: ?NodeId = null,
            height: i32 = 0,
            value: ?Value = null,
            allocated: bool = true,
            generation: u64 = 0,

            fn isLeaf(self: *const Node) bool {
                std.debug.assert((self.left == null) == (self.right == null));
                return self.left == null;
            }
        };

        allocator: std.mem.Allocator,
        nodes: std.ArrayList(Node),
        free_list: std.ArrayList(usize),
        root: ?NodeId = null,
        leaf_count: usize = 0,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .nodes = .empty,
                .free_list = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            self.free_list.deinit(self.allocator);
            self.nodes.deinit(self.allocator);
        }

        pub fn empty(self: *const Self) bool {
            return self.leaf_count == 0;
        }

        pub fn count(self: *const Self) usize {
            return self.leaf_count;
        }

        /// Inserts a leaf box/value and returns a stable id for later updates/removal.
        pub fn insert(self: *Self, bbox: Box, value: Value) Error!NodeId {
            const leaf_id = try self.allocNode(.{
                .bbox = ConfigT.makeTreeBox(bbox),
                .exact_bbox = bbox,
                .value = value,
            });
            errdefer self.freeNode(leaf_id);

            try self.insertLeaf(leaf_id);
            self.leaf_count += 1;
            return leaf_id;
        }

        /// Visits all values whose leaf boxes overlap bbox.
        pub fn query(self: *const Self, bbox: Box, ctx: anytype, cb: anytype) !void {
            var stack: QueryStack = .empty;
            defer stack.deinit(self.allocator);

            try self.queryWithStack(bbox, self.allocator, &stack, ctx, cb);
        }

        /// Visits all values whose leaf boxes overlap bbox, using caller-provided scratch storage.
        pub fn queryWithStack(
            self: *const Self,
            bbox: Box,
            stack_allocator: std.mem.Allocator,
            stack: *QueryStack,
            ctx: anytype,
            cb: anytype,
        ) !void {
            try self.queryImpl(bbox, stack_allocator, stack, ctx, cb, false);
        }

        /// Visits all values whose leaf boxes overlap bbox and includes each leaf id.
        pub fn queryIds(self: *const Self, bbox: Box, ctx: anytype, cb: anytype) !void {
            var stack: QueryStack = .empty;
            defer stack.deinit(self.allocator);

            try self.queryIdsWithStack(bbox, self.allocator, &stack, ctx, cb);
        }

        /// Visits matching leaf ids/values, using caller-provided scratch storage.
        pub fn queryIdsWithStack(
            self: *const Self,
            bbox: Box,
            stack_allocator: std.mem.Allocator,
            stack: *QueryStack,
            ctx: anytype,
            cb: anytype,
        ) !void {
            try self.queryImpl(bbox, stack_allocator, stack, ctx, cb, true);
        }

        fn queryImpl(
            self: *const Self,
            bbox: Box,
            stack_allocator: std.mem.Allocator,
            stack: *QueryStack,
            ctx: anytype,
            cb: anytype,
            comptime include_ids: bool,
        ) !void {
            stack.clearRetainingCapacity();
            defer stack.clearRetainingCapacity();

            const root_id = self.root orelse return;

            try stack.append(stack_allocator, root_id);
            while (stack.items.len > 0) {
                const id = stack.pop().?;
                const current = try self.constNode(id);

                if (!current.bbox.overlaps(&bbox)) {
                    continue;
                }

                if (current.isLeaf()) {
                    if (current.exact_bbox.overlaps(&bbox)) {
                        if (include_ids) {
                            try cb(ctx, id, current.exact_bbox, current.value.?);
                        } else {
                            try cb(ctx, current.exact_bbox, current.value.?);
                        }
                    }
                } else {
                    try stack.append(stack_allocator, current.left.?);
                    try stack.append(stack_allocator, current.right.?);
                }
            }
        }

        /// Removes a leaf id. The id becomes invalid after this call.
        pub fn remove(self: *Self, id: NodeId) Error!void {
            try self.detachLeaf(id);
            self.freeNode(id);
            self.leaf_count -= 1;
        }

        /// Returns the value stored in a leaf id.
        pub fn getValue(self: *const Self, id: NodeId) Error!Value {
            const current = try self.constNodeAsLeaf(id);
            return current.value.?;
        }

        /// Replaces the value stored in a leaf id.
        pub fn setValue(self: *Self, id: NodeId, value: Value) Error!void {
            const current = try self.nodeAsLeaf(id);
            current.value = value;
        }

        /// Returns the current box stored in a leaf id.
        pub fn getBox(self: *const Self, id: NodeId) Error!Box {
            const current = try self.constNodeAsLeaf(id);
            return current.exact_bbox;
        }

        /// Returns the tree box used internally for traversal.
        pub fn getTreeBox(self: *const Self, id: NodeId) Error!Box {
            const current = try self.constNodeAsLeaf(id);
            return current.bbox;
        }

        /// Removes all nodes while retaining allocated capacity.
        pub fn clear(self: *Self) void {
            self.free_list.clearRetainingCapacity();
            for (self.nodes.items, 0..) |*current, index| {
                if (current.allocated) {
                    current.generation +%= 1;
                }
                current.allocated = false;
                self.free_list.appendAssumeCapacity(index);
            }
            self.root = null;
            self.leaf_count = 0;
        }

        /// Updates a leaf box while preserving its id.
        pub fn update(self: *Self, id: NodeId, bbox: Box) Error!void {
            const current = try self.constNode(id);
            if (!current.isLeaf()) {
                return Error.WrongNodeKind;
            }
            if (current.bbox.containsBox(&bbox)) {
                const parent_id = current.parent;
                const updated = try self.nodeMut(id);
                updated.exact_bbox = bbox;
                if (!ConfigT.loose_updates) {
                    updated.bbox = ConfigT.makeTreeBox(bbox);
                    if (parent_id) |pid| {
                        try self.refitAncestors(pid);
                    }
                }
                return;
            }

            try self.detachLeaf(id);
            const updated = try self.nodeMut(id);
            updated.bbox = ConfigT.makeTreeBox(bbox);
            updated.exact_bbox = bbox;
            try self.insertLeaf(id);
        }

        fn allocNode(self: *Self, new_node: Node) Error!NodeId {
            var stored = new_node;
            stored.allocated = true;

            if (self.free_list.items.len > 0) {
                const index = self.free_list.pop().?;
                stored.generation = self.nodes.items[index].generation;
                self.nodes.items[index] = stored;
                return .{ .index = index, .generation = stored.generation };
            }

            try self.free_list.ensureTotalCapacity(self.allocator, self.nodes.items.len + 1);
            try self.nodes.append(self.allocator, stored);
            return .{ .index = self.nodes.items.len - 1, .generation = stored.generation };
        }

        fn freeNode(self: *Self, id: NodeId) void {
            std.debug.assert(id.index < self.nodes.items.len);
            std.debug.assert(self.nodes.items[id.index].allocated);
            std.debug.assert(self.nodes.items[id.index].generation == id.generation);

            self.nodes.items[id.index].allocated = false;
            self.nodes.items[id.index].generation +%= 1;
            self.free_list.appendAssumeCapacity(id.index);
        }

        fn nodeMut(self: *Self, id: NodeId) Error!*Node {
            if (id.index >= self.nodes.items.len) {
                return Error.InvalidNode;
            }
            const current = &self.nodes.items[id.index];
            if (!current.allocated or current.generation != id.generation) {
                return Error.InvalidNode;
            }
            return current;
        }

        fn constNode(self: *const Self, id: NodeId) Error!*const Node {
            if (id.index >= self.nodes.items.len) {
                return Error.InvalidNode;
            }
            const current = &self.nodes.items[id.index];
            if (!current.allocated or current.generation != id.generation) {
                return Error.InvalidNode;
            }
            return current;
        }

        fn nodeAsLeaf(self: *Self, id: NodeId) Error!*Node {
            const current = try self.nodeMut(id);
            if (!current.isLeaf()) {
                return Error.WrongNodeKind;
            }
            return current;
        }

        fn constNodeAsLeaf(self: *const Self, id: NodeId) Error!*const Node {
            const current = try self.constNode(id);
            if (!current.isLeaf()) {
                return Error.WrongNodeKind;
            }
            return current;
        }

        fn insertLeaf(self: *Self, leaf_id: NodeId) Error!void {
            const leaf = try self.nodeMut(leaf_id);
            std.debug.assert(leaf.isLeaf());
            leaf.parent = null;

            const old_root = self.root orelse {
                self.root = leaf_id;
                return;
            };

            const sibling_id = try self.chooseBestSibling(leaf.bbox);
            const sibling = try self.constNode(sibling_id);
            const old_parent_id = sibling.parent;
            const parent_bbox = sibling.bbox.merged(&leaf.bbox);
            const parent_height = sibling.height + 1;

            const parent_id = try self.allocNode(.{
                .bbox = parent_bbox,
                .exact_bbox = parent_bbox,
                .parent = old_parent_id,
                .left = sibling_id,
                .right = leaf_id,
                .height = parent_height,
            });

            (try self.nodeMut(sibling_id)).parent = parent_id;
            (try self.nodeMut(leaf_id)).parent = parent_id;

            if (old_parent_id) |grand_parent_id| {
                const grand_parent = try self.nodeMut(grand_parent_id);
                if (grand_parent.left != null and grand_parent.left.?.eql(sibling_id)) {
                    grand_parent.left = parent_id;
                } else {
                    std.debug.assert(grand_parent.right != null and grand_parent.right.?.eql(sibling_id));
                    grand_parent.right = parent_id;
                }
                try self.refitAncestors(grand_parent_id);
            } else {
                std.debug.assert(old_root.eql(sibling_id));
                self.root = parent_id;
            }
        }

        fn detachLeaf(self: *Self, leaf_id: NodeId) Error!void {
            const leaf = try self.constNode(leaf_id);
            if (!leaf.isLeaf()) {
                return Error.WrongNodeKind;
            }

            const parent_id = leaf.parent orelse {
                std.debug.assert(self.root != null and self.root.?.eql(leaf_id));
                self.root = null;
                return;
            };

            const parent = try self.constNode(parent_id);
            std.debug.assert(!parent.isLeaf());

            const sibling_id = if (parent.left != null and parent.left.?.eql(leaf_id))
                parent.right.?
            else if (parent.right != null and parent.right.?.eql(leaf_id))
                parent.left.?
            else
                return Error.InvalidNode;

            if (parent.parent) |grand_parent_id| {
                const grand_parent = try self.nodeMut(grand_parent_id);
                if (grand_parent.left != null and grand_parent.left.?.eql(parent_id)) {
                    grand_parent.left = sibling_id;
                } else {
                    std.debug.assert(grand_parent.right != null and grand_parent.right.?.eql(parent_id));
                    grand_parent.right = sibling_id;
                }
                (try self.nodeMut(sibling_id)).parent = grand_parent_id;
                try self.refitAncestors(grand_parent_id);
            } else {
                self.root = sibling_id;
                (try self.nodeMut(sibling_id)).parent = null;
            }

            (try self.nodeMut(leaf_id)).parent = null;
            self.freeNode(parent_id);
        }

        fn chooseBestSibling(self: *const Self, bbox: Box) Error!NodeId {
            var current_id = self.root.?;

            while (true) {
                const current = try self.constNode(current_id);
                if (current.isLeaf()) {
                    return current_id;
                }

                const left_id = current.left.?;
                const right_id = current.right.?;
                const left = try self.constNode(left_id);
                const right = try self.constNode(right_id);

                const left_cost = insertionCost(left.bbox, bbox);
                const right_cost = insertionCost(right.bbox, bbox);

                if (left_cost < right_cost) {
                    current_id = left_id;
                } else if (right_cost < left_cost) {
                    current_id = right_id;
                } else if (left.bbox.perimeter() < right.bbox.perimeter()) {
                    current_id = left_id;
                } else {
                    current_id = right_id;
                }
            }
        }

        fn insertionCost(existing: Box, inserted: Box) Box.Coord {
            const merged = existing.merged(&inserted);
            return merged.perimeter() - existing.perimeter();
        }

        fn refitAncestors(self: *Self, start_id: NodeId) Error!void {
            var maybe_id: ?NodeId = start_id;
            while (maybe_id) |id| {
                const balanced_id = try self.balance(id);
                maybe_id = (try self.constNode(balanced_id)).parent;
            }
        }

        fn balance(self: *Self, id: NodeId) Error!NodeId {
            const current = try self.constNode(id);
            if (current.isLeaf()) {
                return id;
            }
            if (current.height < 2) {
                try self.refitNode(id);
                return id;
            }

            const left_id = current.left.?;
            const right_id = current.right.?;
            const left = try self.constNode(left_id);
            const right = try self.constNode(right_id);
            const factor = right.height - left.height;

            if (factor > 1) {
                return self.rotateRightHeavy(id, left_id, right_id);
            }
            if (factor < -1) {
                return self.rotateLeftHeavy(id, left_id, right_id);
            }

            try self.refitNode(id);
            return id;
        }

        fn rotateRightHeavy(self: *Self, a_id: NodeId, b_id: NodeId, c_id: NodeId) Error!NodeId {
            const a = try self.constNode(a_id);
            const old_parent_id = a.parent;
            const c = try self.constNode(c_id);
            const f_id = c.left.?;
            const g_id = c.right.?;

            const b_box = (try self.constNode(b_id)).bbox;
            const f_box = (try self.constNode(f_id)).bbox;
            const g_box = (try self.constNode(g_id)).bbox;
            const f_cost = b_box.merged(&f_box).perimeter();
            const g_cost = b_box.merged(&g_box).perimeter();

            try self.replaceParentChild(old_parent_id, a_id, c_id);

            {
                const c_mut = try self.nodeMut(c_id);
                c_mut.parent = old_parent_id;
                c_mut.left = a_id;
            }
            (try self.nodeMut(a_id)).parent = c_id;

            if (f_cost < g_cost) {
                (try self.nodeMut(a_id)).right = f_id;
                (try self.nodeMut(f_id)).parent = a_id;
                (try self.nodeMut(c_id)).right = g_id;
                (try self.nodeMut(g_id)).parent = c_id;
            } else {
                (try self.nodeMut(a_id)).right = g_id;
                (try self.nodeMut(g_id)).parent = a_id;
                (try self.nodeMut(c_id)).right = f_id;
                (try self.nodeMut(f_id)).parent = c_id;
            }

            try self.refitNode(a_id);
            try self.refitNode(c_id);
            return c_id;
        }

        fn rotateLeftHeavy(self: *Self, a_id: NodeId, b_id: NodeId, c_id: NodeId) Error!NodeId {
            const a = try self.constNode(a_id);
            const old_parent_id = a.parent;
            const b = try self.constNode(b_id);
            const d_id = b.left.?;
            const e_id = b.right.?;

            const c_box = (try self.constNode(c_id)).bbox;
            const d_box = (try self.constNode(d_id)).bbox;
            const e_box = (try self.constNode(e_id)).bbox;
            const d_cost = c_box.merged(&d_box).perimeter();
            const e_cost = c_box.merged(&e_box).perimeter();

            try self.replaceParentChild(old_parent_id, a_id, b_id);

            {
                const b_mut = try self.nodeMut(b_id);
                b_mut.parent = old_parent_id;
                b_mut.right = a_id;
            }
            (try self.nodeMut(a_id)).parent = b_id;

            if (d_cost < e_cost) {
                (try self.nodeMut(a_id)).left = d_id;
                (try self.nodeMut(d_id)).parent = a_id;
                (try self.nodeMut(b_id)).left = e_id;
                (try self.nodeMut(e_id)).parent = b_id;
            } else {
                (try self.nodeMut(a_id)).left = e_id;
                (try self.nodeMut(e_id)).parent = a_id;
                (try self.nodeMut(b_id)).left = d_id;
                (try self.nodeMut(d_id)).parent = b_id;
            }

            try self.refitNode(a_id);
            try self.refitNode(b_id);
            return b_id;
        }

        fn replaceParentChild(self: *Self, parent_id: ?NodeId, old_child_id: NodeId, new_child_id: NodeId) Error!void {
            if (parent_id) |id| {
                const parent = try self.nodeMut(id);
                if (parent.left != null and parent.left.?.eql(old_child_id)) {
                    parent.left = new_child_id;
                } else {
                    std.debug.assert(parent.right != null and parent.right.?.eql(old_child_id));
                    parent.right = new_child_id;
                }
            } else {
                std.debug.assert(self.root != null and self.root.?.eql(old_child_id));
                self.root = new_child_id;
            }
        }

        fn refitNode(self: *Self, id: NodeId) Error!void {
            const current = try self.constNode(id);
            std.debug.assert(!current.isLeaf());

            const left_id = current.left.?;
            const right_id = current.right.?;
            const left = try self.constNode(left_id);
            const right = try self.constNode(right_id);

            const bbox = left.bbox.merged(&right.bbox);
            const height = @max(left.height, right.height) + 1;

            const mutable = try self.nodeMut(id);
            mutable.bbox = bbox;
            mutable.height = height;
        }
    };
}
