const std = @import("std");
const contracts = @import("../../contracts/contracts.zig");
const interfaces = @import("../../contracts/interfaces.zig");

const requiresFnSignature = interfaces.requiresFnSignature;
const requiresErrorDeclaration = interfaces.requiresErrorDeclaration;
const requiresTypeDeclaration = interfaces.requiresTypeDeclaration;

pub const requiresStorageManager = contracts.storage_manager.requiresStorageManager;
pub const requiresPageCache = contracts.page_cache.requiresPageCache;

// The key is the BoundingBox from geometry
pub fn assertKey(comptime K: type) void {
    requiresTypeDeclaration(K, "Coord");
    requiresTypeDeclaration(K, "Point");

    const Coord = K.Coord;
    const Point = K.Point;

    requiresFnSignature(K, "measure", fn (*const K) Coord);
    requiresFnSignature(K, "perimeter", fn (*const K) Coord);
    requiresFnSignature(K, "merged", fn (*const K, *const K) K);
    requiresFnSignature(K, "overlaps", fn (*const K, *const K) bool);
    requiresFnSignature(K, "enlargement", fn (*const K, *const K) Coord);
    requiresFnSignature(K, "overlapMeasure", fn (*const K, *const K) Coord);
    requiresFnSignature(K, "center", fn (*const K) Point);
}

pub fn assertModelAccessor(comptime Model: type) void {
    const A = Model.AccessorType;
    requiresErrorDeclaration(A, "Error");
    const Error = A.Error;

    const NodeIdType = Model.NodeIdType;
    const LeafType = Model.LeafType;
    const InodeType = Model.InodeType;

    requiresFnSignature(A, "getRoot", fn (*const A) ?NodeIdType);
    requiresFnSignature(A, "setRoot", fn (*A, ?NodeIdType) Error!void);
    requiresFnSignature(A, "destroy", fn (*A, NodeIdType) Error!void);

    requiresFnSignature(A, "createLeaf", fn (*A) Error!LeafType);
    requiresFnSignature(A, "createInode", fn (*A) Error!InodeType);
    requiresFnSignature(A, "loadLeaf", fn (*A, ?NodeIdType) Error!?LeafType);
    requiresFnSignature(A, "loadInode", fn (*A, ?NodeIdType) Error!?InodeType);
    requiresFnSignature(A, "deinitLeaf", fn (*A, ?LeafType) void);
    requiresFnSignature(A, "deinitInode", fn (*A, ?InodeType) void);

    requiresFnSignature(A, "isLeafId", fn (*A, NodeIdType) Error!bool);
}

// Common part for Leaf and Inode.
fn assertNodeCommon(comptime Model: type, comptime Node: type) void {
    requiresErrorDeclaration(Node, "Error");

    const Error = Node.Error;
    const KeyType = Model.KeyType;
    const NodeIdType = Model.NodeIdType;

    requiresFnSignature(Node, "id", fn (*const Node) NodeIdType);
    requiresFnSignature(Node, "take", fn (*Node) Error!Node);
    requiresFnSignature(Node, "size", fn (*const Node) Error!usize);
    requiresFnSignature(Node, "capacity", fn (*const Node) Error!usize);
    requiresFnSignature(Node, "getMbr", fn (*const Node, usize) Error!KeyType);
    requiresFnSignature(Node, "nodeMbr", fn (*const Node) Error!KeyType);
    requiresFnSignature(Node, "erase", fn (*Node, usize) Error!void);
    requiresFnSignature(Node, "clear", fn (*Node) Error!void);
    requiresFnSignature(Node, "compact", fn (*Node) Error!void);

    requiresFnSignature(Node, "setParent", fn (*Node, ?NodeIdType) Error!void);
    requiresFnSignature(Node, "getParent", fn (*const Node) Error!?NodeIdType);
}

pub fn assertInode(comptime Model: type) void {
    const I = Model.InodeType;

    const Error = Model.Error;
    const KeyType = Model.KeyType;
    const NodeIdType = Model.NodeIdType;

    assertNodeCommon(Model, I);

    requiresFnSignature(I, "getLevel", fn (*const I) Error!usize);
    requiresFnSignature(I, "setLevel", fn (*I, usize) Error!void);

    requiresFnSignature(I, "getChild", fn (*const I, usize) Error!NodeIdType);
    requiresFnSignature(I, "canInsertChild", fn (*const I, KeyType, NodeIdType) Error!bool);
    requiresFnSignature(I, "insertChild", fn (*I, KeyType, NodeIdType) Error!void);

    requiresFnSignature(I, "updateChildMbr", fn (*I, usize, KeyType) Error!void);
}

pub fn assertLeaf(comptime Model: type) void {
    const L = Model.LeafType;

    const Error = Model.Error;
    const KeyType = Model.KeyType;

    const ValueInType = Model.ValueInType;
    const ValueOutType = Model.ValueOutType;

    assertNodeCommon(Model, L);

    requiresFnSignature(L, "getValue", fn (*const L, usize) Error!ValueOutType);
    requiresFnSignature(L, "canInsertEntry", fn (*const L, KeyType, ValueInType) Error!bool);
    requiresFnSignature(L, "insertEntry", fn (*L, KeyType, ValueInType) Error!void);
}

pub fn assertModel(comptime T: type) void {
    requiresTypeDeclaration(T, "NodeIdType");
    requiresErrorDeclaration(T, "Error");

    requiresTypeDeclaration(T, "KeyType");
    assertKey(T.KeyType);

    requiresTypeDeclaration(T, "ValueInType");
    requiresTypeDeclaration(T, "ValueOutType");

    requiresTypeDeclaration(T, "ValueBufType");

    requiresTypeDeclaration(T, "max_entries");

    requiresTypeDeclaration(T, "LeafType");
    assertLeaf(T);

    requiresTypeDeclaration(T, "InodeType");
    assertInode(T);

    requiresTypeDeclaration(T, "AccessorType");
    assertModelAccessor(T);

    requiresFnSignature(T, "getAccessor", fn (*T) *T.AccessorType);
    requiresFnSignature(T, "valueOutAsIn", fn (*const T, T.ValueOutType) T.ValueInType);
    requiresFnSignature(T, "copyValueOut", fn (*const T, T.ValueOutType) T.ValueBufType);
    requiresFnSignature(T, "valueBufAsIn", fn (*const T, *const T.ValueBufType) T.ValueInType);
    requiresFnSignature(T, "isValidId", fn (*const T, ?T.NodeIdType) bool);
    requiresFnSignature(T, "maxEntries", fn (*const T) usize);
}
