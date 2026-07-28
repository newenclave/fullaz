const std = @import("std");
const errors = @import("../../../core/errors.zig");

const BoundingBox = @import("../../geometry.zig").BoundingBox;

pub fn Memory(comptime T: type, comptime dimention: usize) type {
    const BoundingBoxT = BoundingBox(T, dimention);
    const child_count = 1 << dimention;

    const ErrorSet = std.mem.Allocator.Error ||
        errors.IndexError ||
        errors.SpaceError;

    const Entry = struct {
        bbox: BoundingBoxT,
        data: T,
    };
    const EntryList = std.ArrayList(Entry);

    const Id = usize;

    const Context = struct {
        allocator: std.mem.Allocator,
    };

    const NodeImpl = struct {
        const Self = @This();
        const Children = [child_count]Id;

        entries: EntryList,
        children: ?Children = null,
        ctx: *Context,

        fn init(ctx: *Context) ErrorSet!Self {
            return Self{
                .entries = EntryList.init(ctx.allocator),
                .children = null,
                .ctx = ctx,
            };
        }

        fn deinit(self: *Self) void {
            self.entries.deinit();
        }
    };

    const NodeWrapper = struct {
        const Self = @This();
        node: *NodeImpl,

        // entries count
        pub fn size(self: *const Self) usize {
            return self.node.entries.items.len;
        }

        pub fn isLeaf(self: *const Self) bool {
            return self.node.children == null;
        }
    };

    const NodeList = std.ArrayList(?NodeImpl);

    const AccessorImpl = struct {
        const Self = @This();
        ctx: Context,
        nodes: NodeList,
        root_id: ?Id = null,

        pub fn init(allocator: std.mem.Allocator) ErrorSet!Self {
            const ctx = Context{
                .allocator = allocator,
            };
            return .{
                .ctx = ctx,
                .nodes = NodeList.init(ctx.allocator),
                .root_id = null,
            };
        }

        pub fn deinit(self: *Self) void {
            self.nodes.deinit();
        }

        pub fn getRoot(self: *const Self) ?Id {
            return self.root_id;
        }

        pub fn setRoot(self: *Self, id: ?Id) void {
            self.root_id = id;
        }

        pub fn isLeaf(self: *const Self, id: Id) ErrorSet!bool {
            if (id >= self.nodes.items.len) {
                return ErrorSet.OutOfBounds;
            }
            if (self.nodes.items[id]) |*node| {
                return node.children == null;
            }
            return ErrorSet.OutOfBounds;
        }

        pub fn createNode(self: *Self) ErrorSet!Id {
            const node = try NodeImpl.init(&self.ctx);
            const id = self.nodes.items.len;
            try self.nodes.append(node);
            return id;
        }
    };

    return struct {
        pub const Node = NodeWrapper;
        pub const NodeId = usize;
        const Self = @This();
        pub const Accessor = AccessorImpl;

        accessor: Accessor,

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .ctx = Context{
                    .allocator = allocator,
                },
            };
        }

        pub fn getAccessor(self: *Self) *Accessor {
            return &self.accessor;
        }

        pub fn loadNode(self: *Self, id: NodeId) ErrorSet!Node {
            if (id >= self.accessor.nodes.items.len) {
                return ErrorSet.OutOfBounds;
            }
            if (self.accessor.nodes.items[id]) |*node| {
                return Node{ .node = node };
            }
            return ErrorSet.OutOfBounds;
        }

        // wrapper
        pub fn deinitNode(self: *Self, node: Node) void {
            _ = self;
            _ = node;
        }
    };
}
