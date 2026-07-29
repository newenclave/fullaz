const std = @import("std");
const errors = @import("../../../core/errors.zig");

const BoundingBox = @import("../../geometry.zig").BoundingBox;

const EmptyTrait = @import("traits.zig").Empty;

pub fn Memory(comptime T: type, comptime dimention: usize, comptime ValueT: type) type {
    return MemoryImpl(T, dimention, ValueT, EmptyTrait);
}

pub fn MemoryImpl(
    comptime T: type,
    comptime dimention: usize,
    comptime ValueT: type,
    comptime TraitT: fn (
        comptime T: type,
        comptime dimention: usize,
        comptime ValueT: type,
    ) type,
) type {
    const TraitType = TraitT(T, dimention, ValueT);
    const BoundingBoxT = BoundingBox(T, dimention);
    const child_count = 1 << dimention;

    const ErrorSet = std.mem.Allocator.Error ||
        TraitType.Error ||
        errors.IndexError ||
        errors.SpaceError ||
        error{ AlreadyInitialized, InvalidId };

    const EntryImpl = struct {
        const Self = @This();
        pub const Box = BoundingBoxT;
        pub const Value = ValueT;

        bbox: Box,
        data: Value,

        pub fn getBox(self: *const Self) BoundingBoxT {
            return self.bbox;
        }
        pub fn getData(self: *const Self) ValueT {
            return self.data;
        }
    };
    const EntryList = std.ArrayList(EntryImpl);

    const IdType = usize;

    const Context = struct {
        allocator: std.mem.Allocator,
        max_leaf_entries: usize,
        entries_count: usize = 0,
        level: usize = 0,
        trait: TraitType,
    };

    const NodeImpl = struct {
        const Self = @This();
        const Children = []IdType;
        pub const Box = BoundingBoxT;

        bounds: Box,
        entries: EntryList,
        children: ?Children = null,
        parent: ?IdType = null,
        trait: TraitType,
        ctx: *Context,

        fn init(bounds: Box, ctx: *Context) ErrorSet!Self {
            return Self{
                .bounds = bounds,
                .entries = try EntryList.initCapacity(ctx.allocator, 1),
                .children = null,
                .parent = null,
                .trait = ctx.trait,
                .ctx = ctx,
            };
        }

        fn initInPlace(self: *Self, bounds: Box, ctx: *Context) ErrorSet!void {
            self.ctx = ctx;
            self.bounds = bounds;
            self.entries = try EntryList.initCapacity(ctx.allocator, 1);
            self.children = null;
            self.parent = null;
            self.trait = ctx.trait;
        }

        fn initChildren(self: *Self) ErrorSet!void {
            if (self.children != null) {
                return ErrorSet.AlreadyInitialized;
            }
            const children = try self.ctx.allocator.alloc(IdType, child_count);
            @memset(children, 0);
            self.children = children;
        }

        fn deinit(self: *Self) void {
            if (self.children) |children| {
                self.ctx.allocator.free(children);
            }
            self.entries.deinit(self.ctx.allocator);
        }
    };

    const NodeWrapper = struct {
        const Self = @This();
        pub const Box = BoundingBoxT;
        pub const Value = ValueT;
        pub const Id = IdType;

        node: *NodeImpl,
        node_id: Id,

        fn init(node: *NodeImpl, node_id: Id) ErrorSet!Self {
            return Self{
                .node = node,
                .node_id = node_id,
            };
        }

        // entries count
        pub fn size(self: *const Self) usize {
            return self.node.entries.items.len;
        }

        pub fn isLeaf(self: *const Self) bool {
            return self.node.children == null;
        }

        pub fn bounds(self: *const Self) Box {
            return self.node.bounds;
        }

        pub fn getChild(self: *const Self, index: usize) ?Id {
            if (self.node.children) |children| {
                if (index < child_count) {
                    return children[index];
                }
            }
            return null;
        }

        pub fn getEntry(self: *const Self, index: usize) ErrorSet!EntryImpl {
            if (index >= self.node.entries.items.len) {
                return ErrorSet.OutOfBounds;
            }
            return self.node.entries.items[index];
        }

        pub fn beforeSplit(self: *Self) ErrorSet!void {
            try self.node.initChildren();
        }

        pub fn moveEntryTo(self: *Self, index: usize, target: *Self) ErrorSet!void {
            if (index >= self.node.entries.items.len) {
                return ErrorSet.OutOfBounds;
            }
            const entry = self.node.entries.items[index];
            try target.node.entries.append(target.node.ctx.allocator, entry);
            _ = self.node.entries.orderedRemove(index);
        }

        pub fn canInsertEntry(self: *const Self, box: Box, value: ValueT) bool {
            _ = box;
            _ = value;
            return self.node.entries.items.len < self.node.ctx.max_leaf_entries;
        }

        pub fn canSplit(self: *const Self) bool {
            _ = self;
            return true; // TODO: need to calculate minimum bounding box
        }

        pub fn setLevel(self: *Self, level: usize) void {
            self.node.level = level;
        }

        pub fn getLevel(self: *const Self) usize {
            return self.node.level;
        }

        pub fn getTrait(self: *const Self) *const TraitType {
            return &self.node.trait;
        }

        pub fn getTraitMut(self: *Self) *TraitType {
            return &self.node.trait;
        }

        pub fn addEntry(self: *Self, box: Box, value: ValueT) ErrorSet!void {
            const entry = EntryImpl{
                .bbox = box,
                .data = value,
            };
            try self.node.entries.append(self.node.ctx.allocator, entry);
        }

        pub fn removeEntry(self: *Self, index: usize) ErrorSet!ValueT {
            if (index >= self.node.entries.items.len) {
                return ErrorSet.OutOfBounds;
            }
            return self.node.entries.orderedRemove(index).data;
        }

        pub fn setChild(self: *Self, index: usize, child_id: Id) ErrorSet!void {
            if ((index >= child_count) or (self.node.children == null)) {
                return ErrorSet.OutOfBounds;
            }
            if (self.node.children) |children| {
                children[index] = child_id;
                return;
            }
        }

        pub fn getParent(self: *const Self) ErrorSet!?Id {
            return self.node.parent;
        }

        pub fn setParent(self: *Self, parent: ?Id) ErrorSet!void {
            self.node.parent = parent;
        }

        pub fn id(self: *const Self) Id {
            return self.node_id;
        }
    };

    const NodeList = std.ArrayList(?*NodeImpl);

    const AccessorImpl = struct {
        const Self = @This();
        pub const Box = BoundingBoxT;

        ctx: Context,
        nodes: NodeList,
        root_id: ?IdType = null,

        pub fn init(allocator: std.mem.Allocator, trait: TraitType, max_leaf_entries: usize) ErrorSet!Self {
            const ctx = Context{
                .allocator = allocator,
                .trait = trait,
                .max_leaf_entries = max_leaf_entries,
                .entries_count = 0,
            };
            return .{
                .ctx = ctx,
                .nodes = try NodeList.initCapacity(ctx.allocator, 1),
                .root_id = null,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.nodes.items) |node| {
                if (node) |n| {
                    n.deinit();
                    self.ctx.allocator.destroy(n);
                }
            }
            self.nodes.deinit(self.ctx.allocator);
        }

        pub fn getRoot(self: *const Self) ?IdType {
            return self.root_id;
        }

        pub fn setRoot(self: *Self, id: ?IdType) void {
            self.root_id = id;
        }

        pub fn isLeaf(self: *const Self, id: IdType) ErrorSet!bool {
            if (id >= self.nodes.items.len) {
                return ErrorSet.OutOfBounds;
            }
            if (self.nodes.items[id]) |*node| {
                return node.children == null;
            }
            return ErrorSet.OutOfBounds;
        }

        pub fn deinitNode(self: *Self, node: *NodeWrapper) void {
            _ = self;
            _ = node;
        }

        pub fn loadNode(self: *Self, id: IdType) ErrorSet!NodeWrapper {
            if (id >= self.nodes.items.len) {
                return ErrorSet.OutOfBounds;
            }
            if (self.nodes.items[id]) |node| {
                return NodeWrapper.init(node, id);
            }
            return ErrorSet.InvalidId;
        }

        pub fn destoy(self: *Self, id: IdType) ErrorSet!void {
            if (id >= self.nodes.items.len) {
                return ErrorSet.OutOfBounds;
            }

            if (self.nodes.items[id]) |node| {
                node.deinit();
                self.ctx.allocator.destroy(node);
            }
            self.nodes.items[id] = null;
        }

        pub fn createNode(self: *Self, bounds: Box) ErrorSet!NodeWrapper {
            const id = self.nodes.items.len;
            const node = try self.ctx.allocator.create(NodeImpl);
            try node.initInPlace(bounds, &self.ctx);
            errdefer {
                node.deinit();
                self.ctx.allocator.destroy(node);
            }

            try self.nodes.append(
                self.ctx.allocator,
                node,
            );
            return NodeWrapper{
                .node = node,
                .node_id = id,
            };
        }
    };

    return struct {
        pub const Node = NodeWrapper;
        pub const Entry = EntryImpl;
        pub const NodeId = IdType;
        const Self = @This();
        pub const Accessor = AccessorImpl;

        pub const Box = BoundingBoxT;
        pub const ValueIn = ValueT;
        pub const ValueOut = ValueT;
        pub const ValueBorrow = ValueT;
        pub const Error = ErrorSet;
        pub const Trait = TraitType;

        accessor: Accessor,

        pub fn init(allocator: std.mem.Allocator, max_leaf_entries: usize) ErrorSet!Self {
            return Self{
                .accessor = try Accessor.init(
                    allocator,
                    Trait.init(),
                    max_leaf_entries,
                ),
            };
        }

        pub fn initWithTrait(allocator: std.mem.Allocator, trait: Trait, max_leaf_entries: usize) ErrorSet!Self {
            return Self{
                .accessor = try Accessor.init(
                    allocator,
                    trait,
                    max_leaf_entries,
                ),
            };
        }

        pub fn deinit(self: *Self) void {
            self.accessor.deinit();
        }

        pub fn getAccessor(self: *Self) *Accessor {
            return &self.accessor;
        }

        pub fn incrementEntriesCount(self: *Self) ErrorSet!void {
            self.accessor.ctx.entries_count += 1;
        }

        pub fn decrementEntriesCount(self: *Self) ErrorSet!void {
            self.accessor.ctx.entries_count -= 1;
        }

        pub fn getEntriesCount(self: *Self) ErrorSet!usize {
            return self.accessor.ctx.entries_count;
        }

        pub fn valueBorrowAsIn(self: *Self, value: ValueBorrow) ValueIn {
            _ = self;
            return value;
        }

        pub fn deinitBorrowValue(self: *Self, value: ValueBorrow) void {
            _ = self;
            _ = value;
        }

        pub fn onInsert(self: *Self, node: *Node, box: Box, value: ValueIn) ErrorSet!void {
            _ = self;
            try node.node.trait.onInsert(box, value);
        }

        pub fn onGrow(self: *Self, node: *Node, new_node: *Node) ErrorSet!void {
            _ = self;
            try new_node.node.trait.onGrow(&node.node.trait);
        }

        pub fn onRemove(self: *Self, node: *Node, box: Box, value: ValueIn) ErrorSet!void {
            _ = self;
            try node.node.trait.onRemove(box, value);
        }
    };
}
