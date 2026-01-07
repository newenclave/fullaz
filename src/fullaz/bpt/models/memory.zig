const std = @import("std");

const StaticVector = @import("../../static_vector.zig").StaticVector;
const algos = @import("../../algorithm.zig");

const MemoryPidType = usize;

pub fn TypeMap(comptime T: type) type {
    const info = @typeInfo(T);

    const is_array = info == .array;
    const Child = if (is_array) info.array.child else void;

    return if (is_array) struct {
        pub const Stored = T;
        pub const View = []const Child;
        pub const Owned = T;
        pub const Like = []const Child;
    } else struct {
        pub const Stored = T;
        pub const View = T;
        pub const Owned = T;
        pub const Like = T;
    };
}

fn KeyBorrowTypeWrapper(comptime KeyType: type) type {
    return struct {
        const Self = @This();
        key: KeyType,
        sanitize_ptr: ?*u32 = null,
        fn init(key: KeyType, sanitize_ptr: ?*u32) Self {
            return Self{
                .key = key,
                .sanitize_ptr = sanitize_ptr,
            };
        }
    };
}

fn SimpleVector(comptime KeyT: type, comptime N: usize) type {
    return StaticVector(KeyT, N, void, null);
}

fn MemoryInode(comptime KeyT: type, comptime maximum_elements: usize) type {
    return struct {
        const Self = @This();

        const KeyType = KeyT;
        const ChildType = MemoryPidType;
        right_most_child_id: MemoryPidType = undefined,

        parent_id: ?MemoryPidType = null,
        keys: SimpleVector(KeyType, maximum_elements),
        children: SimpleVector(MemoryPidType, maximum_elements),

        pub fn init() Self {
            return Self{
                .keys = SimpleVector(KeyType, maximum_elements).init(undefined),
                .children = SimpleVector(ChildType, maximum_elements).init(undefined),
            };
        }
    };
}

fn MemoryLeaf(comptime KeyT: type, comptime maximum_elements: usize) type {
    return struct {
        const Self = @This();
        const KeyType = KeyT;
        const ValueType = [16]u8;

        keys: SimpleVector(KeyType, maximum_elements),
        values: SimpleVector(ValueType, maximum_elements),
        parent_id: ?MemoryPidType = null,
        prev: ?MemoryPidType = null,
        next: ?MemoryPidType = null,

        pub fn init() Self {
            return Self{
                .keys = SimpleVector(KeyType, maximum_elements).init(undefined),
                .values = SimpleVector(ValueType, maximum_elements).init(undefined),
                .parent_id = null,
                .prev = null,
                .next = null,
            };
        }
    };
}

fn Node(comptime KeyT: type, comptime maximum_elements: usize) type {
    return union(enum) {
        pub const Inode = MemoryInode(KeyT, maximum_elements);
        pub const Leaf = MemoryLeaf(KeyT, maximum_elements);
        inode: Inode,
        leaf: Leaf,
    };
}

fn MemLeafType(comptime KeyT: type, comptime maximum_elements: usize, comptime cmp: anytype) type {
    return struct {
        const Self = @This();

        const ValueBorrowType = MemoryLeafType.ValueType;
        const ValueInType = TypeMap(ValueBorrowType).View;
        const ValueOutType = TypeMap(ValueBorrowType).View;

        const MemoryLeafType = MemoryLeaf(KeyT, maximum_elements);

        const KeyType = KeyT;
        const KeyLikeType = KeyType;
        const KeyOutType = *KeyType;
        const KeyBorrowType = KeyBorrowTypeWrapper(KeyT);

        leaf: ?*MemoryLeafType = null,
        self_id: MemoryPidType = 0,
        keep_ptr: ?*u32 = null,

        pub fn init(leaf: ?*MemoryLeafType, self_id: MemoryPidType, keep_ptr: ?*u32) Self {
            return Self{
                .leaf = leaf,
                .self_id = self_id,
                .keep_ptr = keep_ptr,
            };
        }

        pub fn move(self: *Self) Self {
            const res = self.*;
            self.leaf = null;
            self.keep_ptr = null;
            return res;
        }

        pub fn size(self: *const Self) usize {
            if (self.leaf) |leaf| {
                return leaf.keys.len;
            }
            return 0;
        }

        pub fn capacity(self: *const Self) usize {
            if (self.leaf) |leaf| {
                return leaf.keys.capacity();
            }
            return 0;
        }

        pub fn isUnderflowed(self: *const Self) bool {
            if (self.leaf) |leaf| {
                return leaf.keys.len < (leaf.keys.capacity() + 1) / 2;
            }
            return false;
        }

        pub fn getKey(self: *const Self, pos: usize) !KeyOutType {
            if (self.leaf) |leaf| {
                if (pos < leaf.keys.len) {
                    return &leaf.keys.data[pos];
                }
                return error.OutOfBounds;
            }
            return error.InvalidNode;
        }

        // pub fn borrowKey(self: *const Self, pos: usize) !KeyBorrowType {
        //     return self.getKey(pos);
        // }

        pub fn getValue(self: *const Self, pos: usize) !ValueOutType {
            if (self.leaf) |leaf| {
                if (pos < leaf.values.len) {
                    return leaf.values.data[pos][0..];
                }
                return error.OutOfBounds;
            }
            return error.InvalidNode;
        }

        // pub fn borrowValue(self: *const Self, pos: usize) !ValueBorrowType {
        //     if (self.leaf) |leaf| {
        //         if (pos < leaf.values.len) {
        //             return leaf.values.data[pos];
        //         }
        //         return error.OutOfBounds;
        //     }
        //     return error.InvalidNode;
        // }

        pub fn keysEqual(_: *const Self, k1: KeyLikeType, k2: KeyLikeType) bool {
            return cmp(k1, k2) == .eq;
        }

        pub fn keyPosition(self: *const Self, key: KeyType) !usize {
            if (self.leaf) |leaf| {
                const slice = leaf.keys.data[0..self.leaf.?.keys.len];
                const pos = try algos.lowerBound(KeyType, slice, key, cmp);
                return pos;
            } else {
                return error.InvalidNode;
            }
        }

        pub fn getNext(self: *const Self) ?MemoryPidType {
            if (self.leaf) |leaf| {
                return if (leaf.next != std.math.maxInt(MemoryPidType)) leaf.next else null;
            }
            return null;
        }

        pub fn getPrev(self: *const Self) ?MemoryPidType {
            if (self.leaf) |leaf| {
                return if (leaf.prev != std.math.maxInt(MemoryPidType)) leaf.prev else null;
            }
            return null;
        }

        pub fn setNext(self: *Self, next_id: ?MemoryPidType) void {
            if (self.leaf) |leaf| {
                leaf.next = next_id;
            }
        }

        pub fn setPrev(self: *Self, prev_id: ?MemoryPidType) void {
            if (self.leaf) |leaf| {
                leaf.prev = prev_id;
            }
        }

        pub fn setParent(self: *Self, parent_id: ?MemoryPidType) void {
            if (self.leaf) |leaf| {
                leaf.parent_id = parent_id;
            }
        }

        pub fn getParent(self: *const Self) ?MemoryPidType {
            if (self.leaf) |leaf| {
                return leaf.parent_id;
            }
            return std.math.maxInt(MemoryPidType);
        }

        pub fn isValid(self: *const Self) bool {
            return self.leaf != null;
        }

        pub fn id(self: *const Self) MemoryPidType {
            return self.self_id;
        }

        // should habve this interface for B+ tree operations
        pub fn canInsertValue(self: *const Self, _: usize, _: KeyLikeType, _: ValueInType) bool {
            if (self.leaf) |leaf| {
                return !leaf.keys.full();
            }
            return false;
        }

        pub fn insertValue(self: *Self, pos: usize, key: KeyType, value: ValueInType) !void {
            if (self.leaf) |leaf| {
                try leaf.values.insert(pos, [_]u8{0} ** 16);
                const len = @min(16, value.len);
                @memcpy(leaf.values.ptrAt(pos).?[0..len], value[0..len]);
                try leaf.keys.insert(pos, key);
            } else {
                return error.InvalidNode;
            }
        }

        pub fn canUpdateValue(self: *const Self, pos: usize, _: KeyLikeType, _: ValueInType) !bool {
            if (self.leaf) |leaf| {
                return pos < leaf.keys.len;
            }
            return error.InvalidNode;
        }

        pub fn updateValue(self: *Self, pos: usize, value: ValueInType) !void {
            if (self.leaf) |leaf| {
                if (pos < leaf.values.len) {
                    const len = @min(16, value.len);
                    @memset(leaf.values.ptrAt(pos).?, 0);
                    @memcpy(leaf.values.ptrAt(pos).?[0..len], value[0..len]);
                    return;
                } else {
                    return error.OutOfBounds;
                }
            }
            return error.InvalidNode;
        }

        pub fn erase(self: *Self, pos: usize) !void {
            if (self.leaf) |leaf| {
                try leaf.keys.remove(pos);
                try leaf.values.remove(pos);
            }
        }
    };
}

fn MemInodeType(comptime KeyT: type, comptime maximum_elements: usize, comptime cmp: anytype) type {
    return struct {
        const Self = @This();
        const KeyLikeType = KeyT;
        const KeyOutType = *KeyT;

        const MemoryInodeType = MemoryInode(KeyT, maximum_elements);

        inode: ?*MemoryInodeType = undefined,
        self_id: MemoryPidType = 0,
        keep_ptr: ?*u32 = null,

        pub fn init(inode: ?*MemoryInodeType, self_id: MemoryPidType, keep_ptr: ?*u32) Self {
            return Self{
                .inode = inode,
                .self_id = self_id,
                .keep_ptr = keep_ptr,
            };
        }

        pub fn move(self: *Self) Self {
            const res = self.*;
            self.inode = null;
            self.keep_ptr = null;
            return res;
        }

        pub fn size(self: *const Self) usize {
            if (self.inode) |inode| {
                return inode.keys.len;
            }
            return 0;
        }

        pub fn capacity(self: *const Self) usize {
            if (self.inode) |inode| {
                return inode.keys.capacity();
            }
            return 0;
        }

        pub fn isUnderflowed(self: *const Self) bool {
            if (self.inode) |inode| {
                return inode.keys.len < (inode.keys.capacity() + 1) / 2;
            }
            return false;
        }

        pub fn keysEqual(_: *const Self, k1: KeyLikeType, k2: KeyLikeType) bool {
            return cmp(k1, k2) == .eq;
        }

        pub fn getKey(self: *const Self, pos: usize) !KeyOutType {
            if (self.inode) |inode| {
                if (pos < inode.keys.len) {
                    return &inode.keys.data[pos];
                }
                return error.OutOfBounds;
            }
            return error.InvalidNode;
        }

        // pub fn borrowKey(self: *const Self, pos: usize) !KeyLikeType {
        //     return self.getKey(pos);
        // }

        pub fn getChild(self: *const Self, pos: usize) !MemoryPidType {
            if (self.inode) |inode| {
                if (pos < inode.children.len) {
                    return inode.children.data[pos];
                } else if (pos == inode.children.size()) {
                    return inode.right_most_child_id;
                }
                return error.OutOfBounds;
            }
            return error.InvalidNode;
        }

        pub fn keyPosition(self: *const Self, key: KeyLikeType) !usize {
            if (self.inode) |inode| {
                const slice = inode.keys.data[0..self.inode.?.keys.len];
                const pos = try algos.upperBound(KeyLikeType, slice, key, cmp);
                return pos;
            }
            return error.InvalidNode;
        }

        pub fn canUpdateKey(self: *const Self, pos: usize, _: KeyLikeType) bool {
            if (self.inode) |inode| {
                return pos < inode.keys.len;
            }
            return false;
        }

        pub fn canInsertChild(self: *const Self, _: usize, _: KeyLikeType, _: MemoryPidType) bool {
            if (self.inode) |inode| {
                return !inode.keys.full();
            }
            return false;
        }

        pub fn insertChild(self: *Self, pos: usize, key: KeyLikeType, child_id: MemoryPidType) !void {
            if (self.inode) |inode| {
                try inode.children.insert(pos, child_id);
                try inode.keys.insert(pos, key);
            }
        }

        pub fn erase(self: *Self, pos: usize) !void {
            if (self.inode) |inode| {
                try inode.keys.remove(pos);
                try inode.children.remove(pos);
            }
        }

        pub fn updateChild(self: *Self, pos: usize, child_id: MemoryPidType) !void {
            if (self.inode) |inode| {
                if (pos < inode.children.len) {
                    inode.children.data[pos] = child_id;
                    return;
                } else if (pos == inode.children.len) {
                    inode.right_most_child_id = child_id;
                    return;
                } else {
                    return error.OutOfBounds;
                }
            }
            return error.InvalidNode;
        }

        pub fn updateKey(self: *Self, pos: usize, key: KeyLikeType) !void {
            if (self.inode) |inode| {
                if (pos < inode.keys.len) {
                    inode.keys.data[pos] = key;
                    return;
                } else {
                    return error.OutOfBounds;
                }
            }
            return error.InvalidNode;
        }

        pub fn setParent(self: *Self, parent_id: ?MemoryPidType) void {
            if (self.inode) |inode| {
                inode.parent_id = parent_id;
            }
        }

        pub fn getParent(self: *const Self) ?MemoryPidType {
            if (self.inode) |inode| {
                return inode.parent_id;
            }
            return null;
        }

        pub fn isValid(self: *const Self) bool {
            return self.inode != null;
        }

        pub fn id(self: *const Self) MemoryPidType {
            return self.self_id;
        }
    };
}

fn Accessor(comptime KeyT: type, comptime maximum_elements: usize, comptime cmp: anytype) type {
    return struct {
        const Self = @This();

        const MemoryInodeType = MemoryInode(KeyT, maximum_elements);
        const MemoryLeafType = MemoryLeaf(KeyT, maximum_elements);

        const NodeType = Node(KeyT, maximum_elements);

        const LeafType = MemLeafType(KeyT, maximum_elements, cmp);
        const InodeType = MemInodeType(KeyT, maximum_elements, cmp);

        const KeyBorrowType = LeafType.KeyBorrowType;

        const RootType = usize;
        root: ?RootType = null,
        nodes: std.ArrayList(?*NodeType),
        allocator: std.mem.Allocator,

        pub fn getRoot(self: *const Self) ?RootType {
            return self.root;
        }
        pub fn setRoot(self: *Self, new_root: ?RootType) void {
            self.root = new_root;
        }
        pub fn hasRoot(self: *const Self) bool {
            return self.root != null;
        }

        pub fn init(allocator: std.mem.Allocator) !Self {
            return Self{
                .root = null,
                .nodes = try std.ArrayList(?*NodeType).initCapacity(allocator, 2),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.nodes.items) |node_ptr| {
                if (node_ptr) |node| {
                    self.allocator.destroy(node);
                }
            }
            self.nodes.deinit(self.allocator);
        }

        pub fn borrowKeyfromInode(self: *Self, inode: *const InodeType, pos: usize) !KeyBorrowType {
            return KeyBorrowType.init((try inode.getKey(pos)).*, try self.allocator.create(u32));
        }

        pub fn borrowKeyfromLeaf(self: *Self, leaf: *const LeafType, pos: usize) !KeyBorrowType {
            return KeyBorrowType.init((try leaf.getKey(pos)).*, try self.allocator.create(u32));
        }

        pub fn deinitBorrowKey(self: *Self, key: KeyBorrowType) void {
            if (key.sanitize_ptr) |ptr| {
                self.allocator.destroy(ptr);
            }
        }

        pub fn deinitLeaf(self: *Self, leaf: ?LeafType) void {
            if (leaf) |l| {
                if (l.keep_ptr) |ptr| {
                    self.allocator.destroy(ptr);
                }
            }
        }

        pub fn deinitInode(self: *Self, inode: ?InodeType) void {
            if (inode) |i| {
                if (i.keep_ptr) |ptr| {
                    self.allocator.destroy(ptr);
                }
            }
        }

        pub fn createLeaf(self: *Self) !LeafType {
            const leaf = try self.allocator.create(NodeType);
            leaf.* = .{ .leaf = MemoryLeafType.init() };
            // initialize leaf if needed
            const idx = self.nodes.items.len;
            try self.nodes.append(self.allocator, leaf);
            const leafResult = LeafType.init(&leaf.leaf, idx, try self.allocator.create(u32));
            return leafResult;
        }

        pub fn createInode(self: *Self) !InodeType {
            const inode = try self.allocator.create(NodeType);
            inode.* = .{ .inode = MemoryInodeType.init() };
            // initialize inode if needed
            const idx = self.nodes.items.len;
            try self.nodes.append(self.allocator, inode);
            const inodeResult = InodeType.init(&inode.inode, idx, try self.allocator.create(u32));
            return inodeResult;
        }

        pub fn loadLeaf(self: *Self, id_opt: ?MemoryPidType) !?LeafType {
            if (id_opt) |id| {
                if (id >= self.nodes.items.len) {
                    return error.InvalidNode;
                }
                const node_ptr = self.nodes.items[id];
                if (node_ptr) |node| {
                    switch (node.*) {
                        .leaf => {
                            return LeafType.init(&node.leaf, id, try self.allocator.create(u32));
                        },
                        else => return null,
                    }
                } else {
                    return null;
                }
            }
            return null;
        }

        pub fn loadInode(self: *Self, id_opt: ?MemoryPidType) !?InodeType {
            if (id_opt) |id| {
                if (id == std.math.maxInt(@TypeOf(id))) {
                    @breakpoint();
                }
                if (id >= self.nodes.items.len) {
                    //std.debug.print("id requested {}", .{id});
                    return error.InvalidNode;
                }
                const node_ptr = self.nodes.items[id];
                if (node_ptr) |node| {
                    switch (node.*) {
                        .inode => {
                            return InodeType.init(&node.inode, id, try self.allocator.create(u32));
                        },
                        else => return null,
                    }
                } else {
                    return null;
                }
            }
            return null;
        }

        pub fn isLeafId(self: *Self, id: MemoryPidType) !bool {
            if (id >= self.nodes.items.len) {
                return error.InvalidNode;
            }
            const node_ptr = self.nodes.items[id];
            if (node_ptr) |node| {
                switch (node.*) {
                    .leaf => return true,
                    else => return false,
                }
            }
            return false;
        }

        pub fn isInodeId(self: *Self, id: MemoryPidType) !bool {
            if (id >= self.nodes.items.len) {
                return error.InvalidNode;
            }
            const node_ptr = self.nodes.items[id];
            if (node_ptr) |node| {
                switch (node.*) {
                    .inode => return true,
                    else => return false,
                }
            }
            return false;
        }

        pub fn destroy(self: *Self, id: MemoryPidType) !void {
            if (id >= self.nodes.items.len) {
                return error.InvalidNode;
            }
            const node_ptr = self.nodes.items[id];
            if (node_ptr) |node| {
                self.allocator.destroy(node);
                self.nodes.items[id] = null;
            }
        }

        pub fn canMergeLeafs(_: *Self, left: *const LeafType, right: *const LeafType) bool {
            const total_size = left.size() + right.size();
            if (total_size <= left.capacity()) {
                return true;
            }
            return false;
        }

        pub fn canMergeInodes(_: *Self, left: *const InodeType, right: *const InodeType) bool {
            const total_size = left.size() + right.size() + 1;
            if (total_size <= left.capacity()) {
                return true;
            }
            return false;
        }
    };
}

pub fn MemoryModel(comptime KeyT: type, comptime maximum_elements: usize, comptime cmp: anytype) type {
    comptime {
        if (maximum_elements < 3) {
            @compileError("maximum_elements must be at least 3. Until I implement better balancing");
        }
    }

    return struct {
        const Self = @This();

        pub const KeyLikeType = KeyT;
        pub const KeyOutType = *KeyT;
        pub const KeyBorrowType = KeyBorrowTypeWrapper(KeyT);

        pub const ValueBorrowType = MemoryLeaf(KeyT, maximum_elements).ValueType;

        pub const ValueInType = TypeMap(ValueBorrowType).View;
        pub const ValueOutType = TypeMap(ValueBorrowType).View;

        pub const AccessorType = Accessor(KeyT, maximum_elements, cmp);
        pub const LeafType = AccessorType.LeafType;
        pub const InodeType = AccessorType.InodeType;

        pub const NodedIdType = usize;

        accessor: AccessorType = undefined,

        pub fn init(allocator: std.mem.Allocator) !Self {
            return Self{
                .accessor = try AccessorType.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.accessor.deinit();
        }

        pub fn getAccessor(self: *Self) *AccessorType {
            return &self.accessor;
        }

        pub fn keyBorrowAsLike(_: *const Self, key: *const KeyBorrowType) KeyLikeType {
            return key.key;
        }

        pub fn keyOutAsLike(_: *const Self, key: KeyOutType) KeyLikeType {
            return key.*;
        }

        pub fn valueBorrowAsIn(_: *const Self, value: *const ValueBorrowType) ValueInType {
            return value[0..];
        }

        pub fn valueOutAsIn(_: *const Self, value: ValueOutType) ValueInType {
            return value;
        }

        pub fn isValidId(_: *const Self, pid: ?MemoryPidType) bool {
            if (pid) |value| {
                return value != std.math.maxInt(MemoryPidType);
            }
            return false;
        }
    };
}
