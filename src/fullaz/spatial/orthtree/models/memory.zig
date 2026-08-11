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

    const SettingsT = struct {
        max_leaf_entries: usize,
        max_tree_depth: usize = 32,
        min_cell_extent: T = 0,
    };

    const ErrorSet = std.mem.Allocator.Error ||
        TraitType.Error ||
        errors.IndexError ||
        errors.SpaceError ||
        error{ AlreadyInitialized, InvalidId };

    const EntryImpl = struct {
        const Self = @This();
        pub const Box = BoundingBoxT;
        pub const ValueOut = ValueT;
        pub const ValueBorrow = ValueT;

        bbox: Box,
        data: ValueT,

        pub fn box(self: *const Self) BoundingBoxT {
            return self.bbox;
        }

        pub fn value(self: *const Self) ValueOut {
            return self.data;
        }

        pub fn valueBorrow(self: *const Self) ValueBorrow {
            return self.data;
        }
    };
    const EntryList = std.ArrayList(EntryImpl);

    const IdType = usize;

    const Context = struct {
        allocator: std.mem.Allocator,
        settings: SettingsT,
        entries_count: usize = 0,
        level: usize = 0,
        trait: TraitType,
    };

    const EntriesStorage = struct {
        const Self = @This();
        pub const Entry = EntryImpl;
        allocator: std.mem.Allocator,
        list: EntryList,

        pub const ReadIterator = struct {
            const Itr = @This();
            list: *const EntryList,
            index: usize,

            pub fn init(list: *const EntryList) Itr {
                return Itr{
                    .list = list,
                    .index = 0,
                };
            }

            pub fn deinit(self: *Itr) void {
                _ = self;
            }

            pub fn next(self: *Itr) ErrorSet!?EntryImpl {
                if (self.index >= self.list.items.len) {
                    return null;
                }
                const entry = self.list.items[self.index];
                self.index += 1;
                return entry;
            }

            pub fn done(self: *Itr) bool {
                return self.index >= self.list.items.len;
            }

            pub fn get(self: *const Itr) ?EntryImpl {
                if (self.index >= self.list.items.len) {
                    return null;
                }
                return self.list.items[self.index];
            }
        };

        pub const Cursor = struct {
            const CursorSelf = @This();

            storage: *Self,
            next_index: usize = 0,
            current_index: ?usize = null,

            pub fn init(storage: *Self) CursorSelf {
                return .{ .storage = storage };
            }

            pub fn deinit(self: *CursorSelf) void {
                _ = self;
            }

            pub fn next(self: *CursorSelf) ErrorSet!?EntryImpl {
                if (self.next_index >= self.storage.list.items.len) {
                    self.current_index = null;
                    return null;
                }
                self.current_index = self.next_index;
                self.next_index += 1;
                return self.storage.list.items[self.current_index.?];
            }

            pub fn removeCurrent(self: *CursorSelf) ErrorSet!ValueT {
                const index = self.current_index orelse return ErrorSet.OutOfBounds;
                const entry = self.storage.list.orderedRemove(index);
                self.next_index = index;
                self.current_index = null;
                return entry.data;
            }

            pub fn moveCurrentTo(self: *CursorSelf, target: *Self) ErrorSet!EntryImpl {
                const index = self.current_index orelse return ErrorSet.OutOfBounds;
                const entry = self.storage.list.items[index];
                try target.append(entry);
                _ = self.storage.list.orderedRemove(index);
                self.next_index = index;
                self.current_index = null;
                return entry;
            }
        };

        fn init(allocator: std.mem.Allocator) ErrorSet!Self {
            return Self{
                .allocator = allocator,
                .list = try EntryList.initCapacity(
                    allocator,
                    1,
                ),
            };
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.list.deinit(allocator);
        }

        pub fn readIterator(self: *const Self) ReadIterator {
            return ReadIterator.init(&self.list);
        }

        pub fn cursor(self: *Self) Cursor {
            return Cursor.init(self);
        }

        fn append(self: *Self, entry: EntryImpl) ErrorSet!void {
            try self.list.append(self.allocator, entry);
        }
    };

    const EntriesWrapper = struct {
        const Self = @This();
        pub const Entry = EntryImpl;
        storage: *EntriesStorage,
        pub const Iterator = EntriesStorage.ReadIterator;

        pub fn init(storage: *EntriesStorage) Self {
            return Self{
                .storage = storage,
            };
        }

        pub fn size(self: *const Self) usize {
            return self.storage.list.items.len;
        }

        pub fn iterator(self: *Self) ErrorSet!Iterator {
            return self.storage.readIterator();
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn get(self: *const Self, index: usize) ?EntryImpl {
            if (index >= self.storage.list.items.len) {
                return null;
            }
            return self.storage.list.items[index];
        }
    };

    const EntriesMutWrapper = struct {
        const Self = @This();
        storage: *EntriesStorage,
        pub const Cursor = EntriesStorage.Cursor;

        pub fn init(storage: *EntriesStorage) Self {
            return .{ .storage = storage };
        }

        pub fn cursor(self: *Self) ErrorSet!Cursor {
            return self.storage.cursor();
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn moveCurrentTo(self: *Self, entry_cursor: *Cursor, target: *Self) ErrorSet!EntryImpl {
            _ = self;
            return entry_cursor.moveCurrentTo(target.storage);
        }

        pub fn removeCurrent(self: *Self, entry_cursor: *Cursor) ErrorSet!ValueT {
            _ = self;
            return entry_cursor.removeCurrent();
        }
    };

    const NodeImpl = struct {
        const Self = @This();
        const Children = []IdType;
        pub const Box = BoundingBoxT;
        pub const Entries = EntriesWrapper;
        pub const Entry = EntryImpl;

        bounds: Box,
        entries: EntriesStorage,
        children: ?Children = null,
        parent: ?IdType = null,
        level: usize = 0,
        trait: TraitType,
        ctx: *Context,

        fn init(bounds: Box, ctx: *Context) ErrorSet!Self {
            return Self{
                .bounds = bounds,
                .entries = try EntriesStorage.init(ctx.allocator),
                .children = null,
                .parent = null,
                .trait = ctx.trait,
                .ctx = ctx,
            };
        }

        fn initInPlace(self: *Self, bounds: Box, ctx: *Context) ErrorSet!void {
            self.ctx = ctx;
            self.bounds = bounds;
            self.entries = try EntriesStorage.init(ctx.allocator);
            self.children = null;
            self.parent = null;
            self.level = 0;
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
        pub const Entries = EntriesWrapper;
        pub const EntriesMut = EntriesMutWrapper;
        pub const Trait = TraitType;

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
            return self.node.entries.list.items.len;
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

        pub fn entries(self: *Self) ErrorSet!EntriesWrapper {
            return EntriesWrapper.init(&self.node.entries);
        }

        pub fn entriesMut(self: *Self) ErrorSet!EntriesMutWrapper {
            return EntriesMutWrapper.init(&self.node.entries);
        }

        pub fn deinitEntries(self: *const Self, ent: anytype) void {
            _ = self;
            _ = ent;
        }

        pub fn getEntry(self: *const Self, index: usize) ErrorSet!EntryImpl {
            if (index >= self.node.entries.list.items.len) {
                return ErrorSet.OutOfBounds;
            }
            return self.node.entries.list.items[index];
        }

        pub fn beforeSplit(self: *Self) ErrorSet!void {
            try self.node.initChildren();
        }

        pub fn moveEntryTo(self: *Self, index: usize, target: *Self) ErrorSet!void {
            if (index >= self.node.entries.list.items.len) {
                return ErrorSet.OutOfBounds;
            }
            const entry = self.node.entries.list.items[index];
            try target.node.entries.append(entry);
            _ = self.node.entries.list.orderedRemove(index);
        }

        pub fn canInsertEntry(self: *const Self, box: Box, value: ValueT) ErrorSet!bool {
            _ = box;
            _ = value;
            return self.node.entries.list.items.len < self.node.ctx.settings.max_leaf_entries;
        }

        pub fn canSplit(self: *const Self) bool {
            const settings = self.node.ctx.settings;
            if (self.node.level >= settings.max_tree_depth) {
                return false;
            }
            return self.bounds().splittable(settings.min_cell_extent);
        }

        pub fn setLevel(self: *Self, level: usize) ErrorSet!void {
            self.node.level = level;
        }

        pub fn getLevel(self: *const Self) usize {
            return self.node.level;
        }

        pub fn getTrait(self: *const Self) *const TraitType {
            return &self.node.trait;
        }

        pub fn getTraitMut(self: *Self) ErrorSet!*TraitType {
            return &self.node.trait;
        }

        pub fn addEntry(self: *Self, box: Box, value: ValueT) ErrorSet!void {
            const entry = EntryImpl{
                .bbox = box,
                .data = value,
            };
            try self.node.entries.append(entry);
        }

        pub fn removeEntry(self: *Self, index: usize) ErrorSet!ValueT {
            if (index >= self.node.entries.list.items.len) {
                return ErrorSet.OutOfBounds;
            }
            return self.node.entries.list.orderedRemove(index).data;
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

        pub fn init(allocator: std.mem.Allocator, trait: TraitType, settings: SettingsT) ErrorSet!Self {
            const ctx = Context{
                .allocator = allocator,
                .trait = trait,
                .settings = settings,
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

        pub fn setRoot(self: *Self, id: ?IdType) ErrorSet!void {
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
        pub const Settings = SettingsT;

        accessor: Accessor,

        pub fn init(allocator: std.mem.Allocator, max_leaf_entries: usize) ErrorSet!Self {
            return initWithSettings(allocator, Trait.init(), .{
                .max_leaf_entries = max_leaf_entries,
            });
        }

        pub fn initWithTrait(allocator: std.mem.Allocator, trait: Trait, max_leaf_entries: usize) ErrorSet!Self {
            return initWithSettings(allocator, trait, .{
                .max_leaf_entries = max_leaf_entries,
            });
        }

        pub fn initWithSettings(
            allocator: std.mem.Allocator,
            trait: Trait,
            settings: SettingsT,
        ) ErrorSet!Self {
            return Self{
                .accessor = try Accessor.init(allocator, trait, settings),
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

        pub fn getEntriesCount(self: *const Self) ErrorSet!usize {
            return self.accessor.ctx.entries_count;
        }

        pub fn valueOutAsIn(self: *const Self, value: ValueOut) ValueIn {
            _ = self;
            return value;
        }

        pub fn valueBorrowAsIn(self: *const Self, value: *const ValueBorrow) ValueIn {
            _ = self;
            return value.*;
        }

        pub fn finalizeBorrowValue(self: *Self, value: *ValueBorrow) ErrorSet!void {
            _ = self;
            _ = value;
        }

        pub fn deinitBorrowValue(self: *Self, value: *ValueBorrow) void {
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

        pub fn onAdopt(self: *Self, src: *Node, target: *Node, box: Box, value: ValueIn) ErrorSet!void {
            _ = self;
            _ = src;
            try target.node.trait.onAdopt(box, value);
        }

        pub fn onRemove(self: *Self, node: *Node, box: Box, value: ValueIn) ErrorSet!void {
            _ = self;
            try node.node.trait.onRemove(box, value);
        }
    };
}
