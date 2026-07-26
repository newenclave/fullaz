const std = @import("std");
const interfaces = @import("../contracts/interfaces.zig");

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
                const updated = try self.node(id);
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
            const updated = try self.node(id);
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

        fn node(self: *Self, id: NodeId) Error!*Node {
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
            const current = try self.node(id);
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
            const leaf = try self.node(leaf_id);
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

            (try self.node(sibling_id)).parent = parent_id;
            (try self.node(leaf_id)).parent = parent_id;

            if (old_parent_id) |grand_parent_id| {
                const grand_parent = try self.node(grand_parent_id);
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
                const grand_parent = try self.node(grand_parent_id);
                if (grand_parent.left != null and grand_parent.left.?.eql(parent_id)) {
                    grand_parent.left = sibling_id;
                } else {
                    std.debug.assert(grand_parent.right != null and grand_parent.right.?.eql(parent_id));
                    grand_parent.right = sibling_id;
                }
                (try self.node(sibling_id)).parent = grand_parent_id;
                try self.refitAncestors(grand_parent_id);
            } else {
                self.root = sibling_id;
                (try self.node(sibling_id)).parent = null;
            }

            (try self.node(leaf_id)).parent = null;
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
                const c_mut = try self.node(c_id);
                c_mut.parent = old_parent_id;
                c_mut.left = a_id;
            }
            (try self.node(a_id)).parent = c_id;

            if (f_cost < g_cost) {
                (try self.node(a_id)).right = f_id;
                (try self.node(f_id)).parent = a_id;
                (try self.node(c_id)).right = g_id;
                (try self.node(g_id)).parent = c_id;
            } else {
                (try self.node(a_id)).right = g_id;
                (try self.node(g_id)).parent = a_id;
                (try self.node(c_id)).right = f_id;
                (try self.node(f_id)).parent = c_id;
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
                const b_mut = try self.node(b_id);
                b_mut.parent = old_parent_id;
                b_mut.right = a_id;
            }
            (try self.node(a_id)).parent = b_id;

            if (d_cost < e_cost) {
                (try self.node(a_id)).left = d_id;
                (try self.node(d_id)).parent = a_id;
                (try self.node(b_id)).left = e_id;
                (try self.node(e_id)).parent = b_id;
            } else {
                (try self.node(a_id)).left = e_id;
                (try self.node(e_id)).parent = a_id;
                (try self.node(b_id)).left = d_id;
                (try self.node(d_id)).parent = b_id;
            }

            try self.refitNode(a_id);
            try self.refitNode(b_id);
            return b_id;
        }

        fn replaceParentChild(self: *Self, parent_id: ?NodeId, old_child_id: NodeId, new_child_id: NodeId) Error!void {
            if (parent_id) |id| {
                const parent = try self.node(id);
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

            const mutable = try self.node(id);
            mutable.bbox = bbox;
            mutable.height = height;
        }
    };
}

//////////// Unit tests //////////////
const TestBox = struct {
    pub const Coord = i64;

    low: Coord,
    high: Coord,

    fn init(low: Coord, high: Coord) TestBox {
        return .{ .low = low, .high = high };
    }

    pub fn merged(self: *const TestBox, other: *const TestBox) TestBox {
        return .{ .low = @min(self.low, other.low), .high = @max(self.high, other.high) };
    }

    pub fn overlaps(self: *const TestBox, other: *const TestBox) bool {
        return self.low < other.high and other.low < self.high;
    }

    pub fn containsBox(self: *const TestBox, other: *const TestBox) bool {
        return other.low >= self.low and other.high <= self.high;
    }

    pub fn perimeter(self: *const TestBox) Coord {
        return self.high - self.low;
    }

    pub fn expanded(self: *const TestBox, amount: Coord) TestBox {
        return .{ .low = self.low - amount, .high = self.high + amount };
    }
};

test "aabb tree node storage reuses freed ids" {
    const TestTree = Tree(TestBox, u64);

    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    const first = try tree.allocNode(.{
        .bbox = TestBox.init(0, 1),
        .exact_bbox = TestBox.init(0, 1),
        .value = 1,
    });
    const second = try tree.allocNode(.{
        .bbox = TestBox.init(1, 2),
        .exact_bbox = TestBox.init(1, 2),
        .value = 2,
    });

    try std.testing.expectEqual(@as(usize, 0), first.index);
    try std.testing.expectEqual(@as(u64, 0), first.generation);
    try std.testing.expectEqual(@as(usize, 1), second.index);
    try std.testing.expectEqual(@as(u64, 0), second.generation);

    tree.freeNode(first);
    try std.testing.expectError(TestTree.Error.InvalidNode, tree.constNode(first));

    const reused = try tree.allocNode(.{
        .bbox = TestBox.init(2, 3),
        .exact_bbox = TestBox.init(2, 3),
        .value = 3,
    });
    try std.testing.expectEqual(first.index, reused.index);
    try std.testing.expect(reused.generation != first.generation);
    try std.testing.expectEqual(@as(u64, 3), (try tree.constNode(reused)).value.?);
}

test "aabb tree node storage rejects invalid ids" {
    const TestTree = Tree(TestBox, u64);

    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    try std.testing.expectError(TestTree.Error.InvalidNode, tree.node(.{
        .index = 0,
        .generation = 0,
    }));

    const id = try tree.allocNode(.{
        .bbox = TestBox.init(0, 1),
        .exact_bbox = TestBox.init(0, 1),
        .value = 1,
    });
    try std.testing.expectEqual(@as(usize, 0), id.index);
    try std.testing.expectEqual(@as(u64, 0), id.generation);
    try std.testing.expectError(TestTree.Error.InvalidNode, tree.node(.{
        .index = 1,
        .generation = 0,
    }));
}

test "aabb tree insert creates a root leaf" {
    const TestTree = Tree(TestBox, u64);

    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    const id = try tree.insert(TestBox.init(0, 1), 100);

    try std.testing.expectEqual(@as(usize, 1), tree.count());
    try std.testing.expect(!tree.empty());
    try std.testing.expectEqual(id, tree.root.?);

    const root = try tree.constNode(tree.root.?);
    try std.testing.expect(root.isLeaf());
    try std.testing.expectEqual(TestBox.init(0, 1), root.bbox);
    try std.testing.expectEqual(@as(u64, 100), root.value.?);
}

test "aabb tree insert creates an internal root for two leaves" {
    const TestTree = Tree(TestBox, u64);

    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    const first = try tree.insert(TestBox.init(0, 1), 100);
    const second = try tree.insert(TestBox.init(2, 3), 200);

    try std.testing.expectEqual(@as(usize, 2), tree.count());

    const root = try tree.constNode(tree.root.?);
    try std.testing.expect(!root.isLeaf());
    try std.testing.expectEqual(TestBox.init(0, 3), root.bbox);
    try std.testing.expectEqual(@as(i32, 1), root.height);
    try std.testing.expectEqual(tree.root.?, (try tree.constNode(first)).parent.?);
    try std.testing.expectEqual(tree.root.?, (try tree.constNode(second)).parent.?);
}

test "aabb tree insert refits ancestors" {
    const TestTree = Tree(TestBox, u64);

    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    _ = try tree.insert(TestBox.init(0, 1), 100);
    _ = try tree.insert(TestBox.init(2, 3), 200);
    _ = try tree.insert(TestBox.init(4, 5), 300);

    const root = try tree.constNode(tree.root.?);
    try std.testing.expectEqual(@as(usize, 3), tree.count());
    try std.testing.expect(!root.isLeaf());
    try std.testing.expectEqual(TestBox.init(0, 5), root.bbox);
    try std.testing.expect(root.height >= 1);
}

const ValidationResult = struct {
    bbox: TestBox,
    height: i32,
    leaves: usize,
};

fn validateSubtree(comptime Id: type, tree: anytype, id: Id, expected_parent: ?Id) !ValidationResult {
    const current = try tree.constNode(id);
    try std.testing.expectEqual(expected_parent, current.parent);

    if (current.isLeaf()) {
        try std.testing.expectEqual(@as(i32, 0), current.height);
        return .{ .bbox = current.bbox, .height = 0, .leaves = 1 };
    }

    const left = try validateSubtree(Id, tree, current.left.?, id);
    const right = try validateSubtree(Id, tree, current.right.?, id);
    const expected_bbox = left.bbox.merged(&right.bbox);
    const expected_height = @max(left.height, right.height) + 1;

    try std.testing.expectEqual(expected_bbox, current.bbox);
    try std.testing.expectEqual(expected_height, current.height);

    return .{
        .bbox = current.bbox,
        .height = current.height,
        .leaves = left.leaves + right.leaves,
    };
}

fn validateTree(tree: anytype) !void {
    if (tree.root) |root_id| {
        const Id = @TypeOf(root_id);
        const result = try validateSubtree(Id, tree, root_id, null);
        try std.testing.expectEqual(tree.count(), result.leaves);
    } else {
        try std.testing.expectEqual(@as(usize, 0), tree.count());
    }
}

fn randomBox(rnd: std.Random) TestBox {
    const low = rnd.intRangeAtMost(i64, -500, 500);
    const width = rnd.intRangeAtMost(i64, 1, 80);
    return TestBox.init(low, low + width);
}

test "aabb tree remove only leaf empties tree" {
    const TestTree = Tree(TestBox, u64);

    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    const id = try tree.insert(TestBox.init(0, 10), 100);
    try tree.remove(id);

    try std.testing.expect(tree.empty());
    try std.testing.expectEqual(@as(usize, 0), tree.count());
    try std.testing.expect(tree.root == null);
    try std.testing.expectError(TestTree.Error.InvalidNode, tree.constNode(id));
}

test "aabb tree remove promotes sibling to root" {
    const TestTree = Tree(TestBox, u64);

    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    const first = try tree.insert(TestBox.init(0, 10), 100);
    const second = try tree.insert(TestBox.init(20, 30), 200);

    try tree.remove(first);

    try std.testing.expectEqual(@as(usize, 1), tree.count());
    try std.testing.expectEqual(second, tree.root.?);

    const root = try tree.constNode(tree.root.?);
    try std.testing.expect(root.isLeaf());
    try std.testing.expect(root.parent == null);
    try std.testing.expectEqual(TestBox.init(20, 30), root.bbox);
    try std.testing.expectEqual(@as(u64, 200), root.value.?);
}

test "aabb tree remove rejects internal node ids" {
    const TestTree = Tree(TestBox, u64);

    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    _ = try tree.insert(TestBox.init(0, 10), 100);
    _ = try tree.insert(TestBox.init(20, 30), 200);

    try std.testing.expectError(TestTree.Error.WrongNodeKind, tree.remove(tree.root.?));
    try std.testing.expectEqual(@as(usize, 2), tree.count());
}

test "aabb tree update inside current box refits without reinserting leaf" {
    const TestTree = Tree(TestBox, u64);

    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    const id = try tree.insert(TestBox.init(0, 100), 100);
    _ = try tree.insert(TestBox.init(200, 300), 200);
    const old_root = tree.root.?;
    const old_parent = (try tree.constNode(id)).parent.?;

    try tree.update(id, TestBox.init(10, 20));

    try std.testing.expectEqual(old_root, tree.root.?);
    try std.testing.expectEqual(old_parent, (try tree.constNode(id)).parent.?);
    try std.testing.expectEqual(TestBox.init(10, 20), try tree.getBox(id));
    try std.testing.expectEqual(TestBox.init(10, 20), (try tree.constNode(id)).bbox);
    try std.testing.expectEqual(TestBox.init(10, 300), (try tree.constNode(tree.root.?)).bbox);
    try validateTree(&tree);
}

test "aabb tree update rejects internal node ids" {
    const TestTree = Tree(TestBox, u64);

    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    _ = try tree.insert(TestBox.init(0, 10), 100);
    _ = try tree.insert(TestBox.init(20, 30), 200);

    try std.testing.expectError(
        TestTree.Error.WrongNodeKind,
        tree.update(tree.root.?, TestBox.init(1, 2)),
    );
}

test "aabb tree balancing keeps ordered inserts shallow" {
    const TestTree = Tree(TestBox, u64);

    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    for (0..100) |i| {
        const x: i64 = @intCast(i * 10);
        _ = try tree.insert(TestBox.init(x, x + 1), @intCast(i));
    }

    try validateTree(&tree);

    const root = try tree.constNode(tree.root.?);
    try std.testing.expect(root.height < 32);
}

fn runRandomInvariantStress(comptime TestTree: type, seed: u64) !void {
    const allocator = std.testing.allocator;
    const operations = 500;
    const max_objects = 96;

    var tree = TestTree.init(allocator);
    defer tree.deinit();

    var ids: std.ArrayList(TestTree.NodeId) = .empty;
    defer ids.deinit(allocator);
    try ids.ensureTotalCapacity(allocator, max_objects);

    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();

    for (0..operations) |step| {
        const action = rnd.intRangeLessThan(u8, 0, 100);

        if (ids.items.len == 0 or (ids.items.len < max_objects and action < 45)) {
            const id = try tree.insert(randomBox(rnd), @intCast(step));
            try ids.append(allocator, id);
        } else if (action < 75) {
            const slot = rnd.intRangeLessThan(usize, 0, ids.items.len);
            try tree.update(ids.items[slot], randomBox(rnd));
        } else {
            const slot = rnd.intRangeLessThan(usize, 0, ids.items.len);
            const removed = ids.items[slot];
            try tree.remove(removed);
            try std.testing.expectError(TestTree.Error.InvalidNode, tree.constNode(removed));
            ids.items[slot] = ids.items[ids.items.len - 1];
            _ = ids.pop().?;
        }

        try std.testing.expectEqual(ids.items.len, tree.count());
        if (step % 17 == 0) {
            try validateTree(&tree);
        }
    }

    try validateTree(&tree);
}

test "aabb tree randomized operations preserve internal invariants" {
    try runRandomInvariantStress(Tree(TestBox, u64), 0xAABB_1A7E_2026);
}

test "aabb fat tree randomized operations preserve internal invariants" {
    try runRandomInvariantStress(FatTree(TestBox, u64, 7), 0xFA7_1A7E_2026);
}

test "aabb tree accessors reject invalid and internal ids" {
    const TestTree = Tree(TestBox, u64);

    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    try std.testing.expectError(
        TestTree.Error.InvalidNode,
        tree.getValue(.{ .index = 0, .generation = 0 }),
    );
    try std.testing.expectError(
        TestTree.Error.InvalidNode,
        tree.getBox(.{ .index = 0, .generation = 0 }),
    );
    try std.testing.expectError(
        TestTree.Error.InvalidNode,
        tree.getTreeBox(.{ .index = 0, .generation = 0 }),
    );
    try std.testing.expectError(
        TestTree.Error.InvalidNode,
        tree.setValue(.{ .index = 0, .generation = 0 }, 100),
    );

    _ = try tree.insert(TestBox.init(0, 10), 100);
    _ = try tree.insert(TestBox.init(20, 30), 200);

    try std.testing.expectError(TestTree.Error.WrongNodeKind, tree.getValue(tree.root.?));
    try std.testing.expectError(TestTree.Error.WrongNodeKind, tree.getBox(tree.root.?));
    try std.testing.expectError(TestTree.Error.WrongNodeKind, tree.getTreeBox(tree.root.?));
    try std.testing.expectError(TestTree.Error.WrongNodeKind, tree.setValue(tree.root.?, 300));
}
