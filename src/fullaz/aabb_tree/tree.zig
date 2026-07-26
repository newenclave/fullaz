const std = @import("std");
const interfaces = @import("../contracts/interfaces.zig");

const requiresFnSignature = interfaces.requiresFnSignature;
const requiresTypeDeclaration = interfaces.requiresTypeDeclaration;

pub fn assertBox(comptime BoxT: type) void {
    requiresTypeDeclaration(BoxT, "Coord");

    const Coord = BoxT.Coord;

    requiresFnSignature(BoxT, "merged", fn (*const BoxT, *const BoxT) BoxT);
    requiresFnSignature(BoxT, "overlaps", fn (*const BoxT, *const BoxT) bool);
    requiresFnSignature(BoxT, "perimeter", fn (*const BoxT) Coord);
}

pub fn Tree(comptime BoxT: type, comptime ValueT: type) type {
    comptime assertBox(BoxT);

    const Box = BoxT;
    const Value = ValueT;

    return struct {
        const Self = @This();

        pub const NodeId = usize;
        pub const Error = error{ InvalidNode, WrongNodeKind } || std.mem.Allocator.Error;

        const Node = struct {
            bbox: Box,
            parent: ?NodeId = null,
            left: ?NodeId = null,
            right: ?NodeId = null,
            height: i32 = 0,
            value: ?Value = null,
            allocated: bool = true,

            fn isLeaf(self: *const Node) bool {
                std.debug.assert((self.left == null) == (self.right == null));
                return self.left == null;
            }
        };

        allocator: std.mem.Allocator,
        nodes: std.ArrayList(Node),
        free_list: std.ArrayList(NodeId),
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
                .bbox = bbox,
                .value = value,
            });
            errdefer self.freeNode(leaf_id);

            try self.insertLeaf(leaf_id);
            self.leaf_count += 1;
            return leaf_id;
        }

        /// Visits all values whose leaf boxes overlap bbox.
        pub fn query(self: *const Self, bbox: Box, ctx: anytype, cb: anytype) !void {
            const root_id = self.root orelse return;

            var stack: std.ArrayList(NodeId) = .empty;
            defer stack.deinit(self.allocator);

            try stack.append(self.allocator, root_id);
            while (stack.items.len > 0) {
                const id = stack.pop().?;
                const current = try self.constNode(id);

                if (!current.bbox.overlaps(&bbox)) {
                    continue;
                }

                if (current.isLeaf()) {
                    try cb(ctx, current.bbox, current.value.?);
                } else {
                    try stack.append(self.allocator, current.left.?);
                    try stack.append(self.allocator, current.right.?);
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
            return current.bbox;
        }

        /// Removes all nodes while retaining allocated capacity.
        pub fn clear(self: *Self) void {
            self.nodes.clearRetainingCapacity();
            self.free_list.clearRetainingCapacity();
            self.root = null;
            self.leaf_count = 0;
        }

        /// Updates a leaf box while preserving its id.
        pub fn update(self: *Self, id: NodeId, bbox: Box) Error!void {
            const current = try self.constNode(id);
            if (!current.isLeaf()) {
                return Error.WrongNodeKind;
            }

            try self.detachLeaf(id);
            (try self.node(id)).bbox = bbox;
            try self.insertLeaf(id);
        }

        fn allocNode(self: *Self, new_node: Node) Error!NodeId {
            var stored = new_node;
            stored.allocated = true;

            if (self.free_list.items.len > 0) {
                const id = self.free_list.pop().?;
                self.nodes.items[id] = stored;
                return id;
            }

            try self.free_list.ensureTotalCapacity(self.allocator, self.nodes.items.len + 1);
            try self.nodes.append(self.allocator, stored);
            return self.nodes.items.len - 1;
        }

        fn freeNode(self: *Self, id: NodeId) void {
            std.debug.assert(id < self.nodes.items.len);
            std.debug.assert(self.nodes.items[id].allocated);

            self.nodes.items[id].allocated = false;
            self.free_list.appendAssumeCapacity(id);
        }

        fn node(self: *Self, id: NodeId) Error!*Node {
            if (id >= self.nodes.items.len or !self.nodes.items[id].allocated) {
                return Error.InvalidNode;
            }
            return &self.nodes.items[id];
        }

        fn constNode(self: *const Self, id: NodeId) Error!*const Node {
            if (id >= self.nodes.items.len or !self.nodes.items[id].allocated) {
                return Error.InvalidNode;
            }
            return &self.nodes.items[id];
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
                .parent = old_parent_id,
                .left = sibling_id,
                .right = leaf_id,
                .height = parent_height,
            });

            (try self.node(sibling_id)).parent = parent_id;
            (try self.node(leaf_id)).parent = parent_id;

            if (old_parent_id) |grand_parent_id| {
                const grand_parent = try self.node(grand_parent_id);
                if (grand_parent.left == sibling_id) {
                    grand_parent.left = parent_id;
                } else {
                    std.debug.assert(grand_parent.right == sibling_id);
                    grand_parent.right = parent_id;
                }
                try self.refitAncestors(grand_parent_id);
            } else {
                std.debug.assert(old_root == sibling_id);
                self.root = parent_id;
            }
        }

        fn detachLeaf(self: *Self, leaf_id: NodeId) Error!void {
            const leaf = try self.constNode(leaf_id);
            if (!leaf.isLeaf()) {
                return Error.WrongNodeKind;
            }

            const parent_id = leaf.parent orelse {
                std.debug.assert(self.root == leaf_id);
                self.root = null;
                return;
            };

            const parent = try self.constNode(parent_id);
            std.debug.assert(!parent.isLeaf());

            const sibling_id = if (parent.left == leaf_id)
                parent.right.?
            else if (parent.right == leaf_id)
                parent.left.?
            else
                return Error.InvalidNode;

            if (parent.parent) |grand_parent_id| {
                const grand_parent = try self.node(grand_parent_id);
                if (grand_parent.left == parent_id) {
                    grand_parent.left = sibling_id;
                } else {
                    std.debug.assert(grand_parent.right == parent_id);
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
                if (parent.left == old_child_id) {
                    parent.left = new_child_id;
                } else {
                    std.debug.assert(parent.right == old_child_id);
                    parent.right = new_child_id;
                }
            } else {
                std.debug.assert(self.root == old_child_id);
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

    pub fn perimeter(self: *const TestBox) Coord {
        return self.high - self.low;
    }
};

test "aabb tree node storage reuses freed ids" {
    const TestTree = Tree(TestBox, u64);

    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    const first = try tree.allocNode(.{ .bbox = TestBox.init(0, 1), .value = 1 });
    const second = try tree.allocNode(.{ .bbox = TestBox.init(1, 2), .value = 2 });

    try std.testing.expectEqual(@as(TestTree.NodeId, 0), first);
    try std.testing.expectEqual(@as(TestTree.NodeId, 1), second);

    tree.freeNode(first);
    try std.testing.expectError(TestTree.Error.InvalidNode, tree.constNode(first));

    const reused = try tree.allocNode(.{ .bbox = TestBox.init(2, 3), .value = 3 });
    try std.testing.expectEqual(first, reused);
    try std.testing.expectEqual(@as(u64, 3), (try tree.constNode(reused)).value.?);
}

test "aabb tree node storage rejects invalid ids" {
    const TestTree = Tree(TestBox, u64);

    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    try std.testing.expectError(TestTree.Error.InvalidNode, tree.node(0));

    const id = try tree.allocNode(.{ .bbox = TestBox.init(0, 1), .value = 1 });
    try std.testing.expectEqual(@as(TestTree.NodeId, 0), id);
    try std.testing.expectError(TestTree.Error.InvalidNode, tree.node(1));
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

const QueryCtx = struct {
    values: std.ArrayList(u64),

    fn init() QueryCtx {
        return .{ .values = .empty };
    }

    fn deinit(self: *QueryCtx) void {
        self.values.deinit(std.testing.allocator);
    }
};

fn collectQuery(ctx: *QueryCtx, _: TestBox, value: u64) !void {
    try ctx.values.append(std.testing.allocator, value);
}

fn containsValue(values: []const u64, needle: u64) bool {
    for (values) |value| {
        if (value == needle) {
            return true;
        }
    }
    return false;
}

const ValidationResult = struct {
    bbox: TestBox,
    height: i32,
    leaves: usize,
};

fn validateSubtree(tree: *const Tree(TestBox, u64), id: Tree(TestBox, u64).NodeId, expected_parent: ?Tree(TestBox, u64).NodeId) !ValidationResult {
    const current = try tree.constNode(id);
    try std.testing.expectEqual(expected_parent, current.parent);

    if (current.isLeaf()) {
        try std.testing.expectEqual(@as(i32, 0), current.height);
        return .{ .bbox = current.bbox, .height = 0, .leaves = 1 };
    }

    const left = try validateSubtree(tree, current.left.?, id);
    const right = try validateSubtree(tree, current.right.?, id);
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

fn validateTree(tree: *const Tree(TestBox, u64)) !void {
    if (tree.root) |root_id| {
        const result = try validateSubtree(tree, root_id, null);
        try std.testing.expectEqual(tree.count(), result.leaves);
    } else {
        try std.testing.expectEqual(@as(usize, 0), tree.count());
    }
}

test "aabb tree query on empty tree returns nothing" {
    const TestTree = Tree(TestBox, u64);

    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    var ctx = QueryCtx.init();
    defer ctx.deinit();

    try tree.query(TestBox.init(0, 1), &ctx, collectQuery);
    try std.testing.expectEqual(@as(usize, 0), ctx.values.items.len);
}

test "aabb tree query returns matching leaves" {
    const TestTree = Tree(TestBox, u64);

    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    _ = try tree.insert(TestBox.init(0, 10), 100);
    _ = try tree.insert(TestBox.init(20, 30), 200);
    _ = try tree.insert(TestBox.init(25, 40), 300);

    var ctx = QueryCtx.init();
    defer ctx.deinit();

    try tree.query(TestBox.init(24, 26), &ctx, collectQuery);
    try std.testing.expectEqual(@as(usize, 2), ctx.values.items.len);
    try std.testing.expect(containsValue(ctx.values.items, 200));
    try std.testing.expect(containsValue(ctx.values.items, 300));
}

test "aabb tree query skips non-overlapping leaves" {
    const TestTree = Tree(TestBox, u64);

    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    _ = try tree.insert(TestBox.init(0, 10), 100);
    _ = try tree.insert(TestBox.init(20, 30), 200);

    var ctx = QueryCtx.init();
    defer ctx.deinit();

    try tree.query(TestBox.init(10, 20), &ctx, collectQuery);
    try std.testing.expectEqual(@as(usize, 0), ctx.values.items.len);
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

test "aabb tree remove refits ancestors and excludes removed value" {
    const TestTree = Tree(TestBox, u64);

    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    _ = try tree.insert(TestBox.init(0, 10), 100);
    const removed = try tree.insert(TestBox.init(20, 30), 200);
    _ = try tree.insert(TestBox.init(25, 40), 300);

    try tree.remove(removed);

    const root = try tree.constNode(tree.root.?);
    try std.testing.expectEqual(@as(usize, 2), tree.count());
    try std.testing.expectEqual(TestBox.init(0, 40), root.bbox);

    var ctx = QueryCtx.init();
    defer ctx.deinit();

    try tree.query(TestBox.init(24, 26), &ctx, collectQuery);
    try std.testing.expectEqual(@as(usize, 1), ctx.values.items.len);
    try std.testing.expect(containsValue(ctx.values.items, 300));
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

test "aabb tree update keeps id and moves leaf into query" {
    const TestTree = Tree(TestBox, u64);

    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    const id = try tree.insert(TestBox.init(0, 10), 100);
    _ = try tree.insert(TestBox.init(20, 30), 200);

    try tree.update(id, TestBox.init(22, 24));

    try std.testing.expectEqual(@as(usize, 2), tree.count());
    try std.testing.expectEqual(TestBox.init(22, 24), (try tree.constNode(id)).bbox);

    var ctx = QueryCtx.init();
    defer ctx.deinit();

    try tree.query(TestBox.init(21, 25), &ctx, collectQuery);
    try std.testing.expectEqual(@as(usize, 2), ctx.values.items.len);
    try std.testing.expect(containsValue(ctx.values.items, 100));
    try std.testing.expect(containsValue(ctx.values.items, 200));
}

test "aabb tree update keeps id and moves leaf out of query" {
    const TestTree = Tree(TestBox, u64);

    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    const id = try tree.insert(TestBox.init(0, 10), 100);
    _ = try tree.insert(TestBox.init(20, 30), 200);

    try tree.update(id, TestBox.init(40, 50));

    var ctx = QueryCtx.init();
    defer ctx.deinit();

    try tree.query(TestBox.init(0, 10), &ctx, collectQuery);
    try std.testing.expectEqual(@as(usize, 0), ctx.values.items.len);

    try tree.query(TestBox.init(45, 46), &ctx, collectQuery);
    try std.testing.expectEqual(@as(usize, 1), ctx.values.items.len);
    try std.testing.expect(containsValue(ctx.values.items, 100));
}

test "aabb tree update works for root leaf" {
    const TestTree = Tree(TestBox, u64);

    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    const id = try tree.insert(TestBox.init(0, 10), 100);
    try tree.update(id, TestBox.init(20, 30));

    try std.testing.expectEqual(id, tree.root.?);
    try std.testing.expectEqual(@as(usize, 1), tree.count());
    try std.testing.expectEqual(TestBox.init(20, 30), (try tree.constNode(id)).bbox);
}

test "aabb tree update rejects internal node ids" {
    const TestTree = Tree(TestBox, u64);

    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    _ = try tree.insert(TestBox.init(0, 10), 100);
    _ = try tree.insert(TestBox.init(20, 30), 200);

    try std.testing.expectError(TestTree.Error.WrongNodeKind, tree.update(tree.root.?, TestBox.init(1, 2)));
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

test "aabb tree balancing preserves query correctness" {
    const TestTree = Tree(TestBox, u64);

    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    for (0..64) |i| {
        const x: i64 = @intCast(i * 10);
        _ = try tree.insert(TestBox.init(x, x + 4), @intCast(i));
    }

    try validateTree(&tree);

    var ctx = QueryCtx.init();
    defer ctx.deinit();

    try tree.query(TestBox.init(300, 315), &ctx, collectQuery);
    try std.testing.expectEqual(@as(usize, 2), ctx.values.items.len);
    try std.testing.expect(containsValue(ctx.values.items, 30));
    try std.testing.expect(containsValue(ctx.values.items, 31));
}

test "aabb tree accessors read and update leaf values" {
    const TestTree = Tree(TestBox, u64);

    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    const id = try tree.insert(TestBox.init(0, 10), 100);

    try std.testing.expectEqual(@as(u64, 100), try tree.getValue(id));
    try std.testing.expectEqual(TestBox.init(0, 10), try tree.getBox(id));

    try tree.setValue(id, 200);
    try std.testing.expectEqual(@as(u64, 200), try tree.getValue(id));
}

test "aabb tree accessors reject invalid and internal ids" {
    const TestTree = Tree(TestBox, u64);

    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    try std.testing.expectError(TestTree.Error.InvalidNode, tree.getValue(0));
    try std.testing.expectError(TestTree.Error.InvalidNode, tree.getBox(0));
    try std.testing.expectError(TestTree.Error.InvalidNode, tree.setValue(0, 100));

    _ = try tree.insert(TestBox.init(0, 10), 100);
    _ = try tree.insert(TestBox.init(20, 30), 200);

    try std.testing.expectError(TestTree.Error.WrongNodeKind, tree.getValue(tree.root.?));
    try std.testing.expectError(TestTree.Error.WrongNodeKind, tree.getBox(tree.root.?));
    try std.testing.expectError(TestTree.Error.WrongNodeKind, tree.setValue(tree.root.?, 300));
}

test "aabb tree clear empties tree and allows reuse" {
    const TestTree = Tree(TestBox, u64);

    var tree = TestTree.init(std.testing.allocator);
    defer tree.deinit();

    const old_id = try tree.insert(TestBox.init(0, 10), 100);
    _ = try tree.insert(TestBox.init(20, 30), 200);

    tree.clear();

    try std.testing.expect(tree.empty());
    try std.testing.expectEqual(@as(usize, 0), tree.count());
    try std.testing.expect(tree.root == null);
    try std.testing.expectError(TestTree.Error.InvalidNode, tree.getValue(old_id));

    const new_id = try tree.insert(TestBox.init(40, 50), 300);
    try std.testing.expectEqual(@as(TestTree.NodeId, 0), new_id);
    try std.testing.expectEqual(@as(u64, 300), try tree.getValue(new_id));
    try validateTree(&tree);
}
