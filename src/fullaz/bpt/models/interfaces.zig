const std = @import("std");
const interfaces = @import("../../contracts/interfaces.zig");

const requiresFnSignature = interfaces.requiresFnSignature;
const requiresFnReturnsError = interfaces.requiresFnReturnsAnyError;
const requiresErrorDeclaration = interfaces.requiresErrorDeclaration;
const requiresTypeDeclaration = interfaces.requiresTypeDeclaration;

pub fn requireStorageManager(comptime T: type) void {
    requiresErrorDeclaration(T, "Error");
    const Error = T.Error;
    requiresTypeDeclaration(T, "PageId");
    requiresFnSignature(T, "getRoot", fn (*const T) ?T.PageId);
    requiresFnSignature(T, "setRoot", fn (*T, ?T.PageId) Error!void);
    requiresFnSignature(T, "hasRoot", fn (*const T) bool);
    requiresFnSignature(T, "destroyPage", fn (*T, T.PageId) Error!void);
}

pub fn assertModelAccessor(comptime Model: type) void {
    const A = Model.AccessorType;
    requiresErrorDeclaration(A, "Error");
    const Error = A.Error;

    const NodeIdType = Model.NodeIdType;
    const LeafType = Model.LeafType;
    const InodeType = Model.InodeType;
    const KeyBorrowType = Model.KeyBorrowType;

    requiresFnSignature(A, "getRoot", fn (*const A) ?NodeIdType);
    requiresFnSignature(A, "setRoot", fn (*A, ?NodeIdType) Error!void);
    requiresFnSignature(A, "hasRoot", fn (*const A) bool);
    requiresFnSignature(A, "destroy", fn (*A, NodeIdType) Error!void);

    requiresFnSignature(A, "createLeaf", fn (*A) Error!LeafType);
    requiresFnSignature(A, "createInode", fn (*A) Error!InodeType);
    requiresFnSignature(A, "loadLeaf", fn (*A, ?NodeIdType) Error!?LeafType);
    requiresFnSignature(A, "loadInode", fn (*A, ?NodeIdType) Error!?InodeType);
    requiresFnSignature(A, "deinitLeaf", fn (*A, ?LeafType) void);
    requiresFnSignature(A, "deinitInode", fn (*A, ?InodeType) void);

    requiresFnSignature(A, "isLeafId", fn (*A, NodeIdType) Error!bool);

    requiresFnSignature(A, "borrowKeyfromInode", fn (*A, *const InodeType, usize) Error!KeyBorrowType);
    requiresFnSignature(A, "borrowKeyfromLeaf", fn (*A, *const LeafType, usize) Error!KeyBorrowType);
    requiresFnSignature(A, "deinitBorrowKey", fn (*A, KeyBorrowType) void);

    requiresFnSignature(A, "canMergeLeafs", fn (*A, *const LeafType, *const LeafType) Error!bool);
    requiresFnSignature(A, "canMergeInodes", fn (*A, *const InodeType, *const InodeType) Error!bool);
}

fn assertNodeCommon(comptime Model: type, comptime Node: type) void {
    requiresErrorDeclaration(Node, "Error");

    const Error = Node.Error;
    const KeyLikeType = Model.KeyLikeType;
    const KeyOutType = Model.KeyOutType;
    const NodeIdType = Model.NodeIdType;

    requiresFnSignature(Node, "id", fn (*const Node) NodeIdType);
    requiresFnSignature(Node, "take", fn (*Node) Error!Node);
    requiresFnSignature(Node, "size", fn (*const Node) Error!usize);
    requiresFnSignature(Node, "capacity", fn (*const Node) Error!usize);
    requiresFnSignature(Node, "isUnderflowed", fn (*const Node) Error!bool);
    requiresFnSignature(Node, "keysEqual", fn (*const Node, KeyLikeType, KeyLikeType) bool);
    requiresFnSignature(Node, "keyPosition", fn (*const Node, KeyLikeType) Error!usize);
    requiresFnSignature(Node, "getKey", fn (*const Node, usize) Error!KeyOutType);
    requiresFnSignature(Node, "erase", fn (*Node, usize) Error!void);
    requiresFnSignature(Node, "setParent", fn (*Node, ?NodeIdType) Error!void);
    requiresFnSignature(Node, "getParent", fn (*const Node) ?NodeIdType);
}

pub fn assertInode(comptime Model: type) void {
    const I = Model.InodeType;

    const Error = Model.Error;
    const KeyLikeType = Model.KeyLikeType;
    const NodeIdType = Model.NodeIdType;

    assertNodeCommon(Model, I);

    requiresFnSignature(I, "getChild", fn (*const I, usize) Error!NodeIdType);
    requiresFnSignature(I, "canUpdateKey", fn (*const I, usize, KeyLikeType) Error!bool);
    requiresFnSignature(I, "updateKey", fn (*I, usize, KeyLikeType) Error!void);

    requiresFnSignature(I, "canInsertChild", fn (*const I, usize, KeyLikeType, NodeIdType) Error!bool);
    requiresFnSignature(I, "insertChild", fn (*I, usize, KeyLikeType, NodeIdType) Error!void);
    requiresFnSignature(I, "updateChild", fn (*I, usize, NodeIdType) Error!void);
}

pub fn assertLeaf(comptime Model: type) void {
    const L = Model.LeafType;

    const Error = Model.Error;
    const KeyLikeType = Model.KeyLikeType;
    const NodeIdType = Model.NodeIdType;

    const ValueInType = Model.ValueInType;
    const ValueOutType = Model.ValueOutType;

    assertNodeCommon(Model, L);

    requiresFnSignature(L, "getValue", fn (*const L, usize) Error!ValueOutType);
    requiresFnSignature(L, "setPrev", fn (*L, ?NodeIdType) Error!void);
    requiresFnSignature(L, "getPrev", fn (*const L) ?NodeIdType);
    requiresFnSignature(L, "setNext", fn (*L, ?NodeIdType) Error!void);
    requiresFnSignature(L, "getNext", fn (*const L) ?NodeIdType);

    requiresFnSignature(L, "canInsertValue", fn (*const L, usize, KeyLikeType, ValueInType) Error!bool);
    requiresFnSignature(L, "insertValue", fn (*L, usize, KeyLikeType, ValueInType) Error!void);

    requiresFnSignature(L, "canUpdateValue", fn (*const L, usize, ValueInType) Error!bool);
    requiresFnSignature(L, "updateValue", fn (*L, usize, ValueInType) Error!void);
}

pub fn assertModel(comptime T: type) void {
    requiresTypeDeclaration(T, "NodeIdType");
    requiresErrorDeclaration(T, "Error");

    requiresTypeDeclaration(T, "KeyLikeType");
    requiresTypeDeclaration(T, "KeyOutType");
    requiresTypeDeclaration(T, "KeyBorrowType");

    requiresTypeDeclaration(T, "ValueInType");
    requiresTypeDeclaration(T, "ValueOutType");

    requiresTypeDeclaration(T, "LeafType");
    assertLeaf(T);

    requiresTypeDeclaration(T, "InodeType");
    assertInode(T);

    requiresTypeDeclaration(T, "AccessorType");
    assertModelAccessor(T);

    // calls:
    requiresFnSignature(T, "getAccessor", fn (*T) *T.AccessorType);
    requiresFnSignature(T, "keyBorrowAsLike", fn (*const T, *const T.KeyBorrowType) T.KeyLikeType);
    requiresFnSignature(T, "keyOutAsLike", fn (*const T, T.KeyOutType) T.KeyLikeType);
    requiresFnSignature(T, "valueOutAsIn", fn (*const T, T.ValueOutType) T.ValueInType);
    requiresFnSignature(T, "isValidId", fn (*const T, ?T.NodeIdType) bool);
}
