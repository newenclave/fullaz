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
        pub const Error = error{InvalidNode} || std.mem.Allocator.Error;

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

        fn allocNode(self: *Self, new_node: Node) Error!NodeId {
            var stored = new_node;
            stored.allocated = true;

            if (self.free_list.items.len > 0) {
                const id = self.free_list.pop().?;
                self.nodes.items[id] = stored;
                return id;
            }

            try self.nodes.append(self.allocator, stored);
            return self.nodes.items.len - 1;
        }

        fn freeNode(self: *Self, id: NodeId) Error!void {
            std.debug.assert(id < self.nodes.items.len);
            std.debug.assert(self.nodes.items[id].allocated);

            self.nodes.items[id].allocated = false;
            try self.free_list.append(self.allocator, id);
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

    try tree.freeNode(first);
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
