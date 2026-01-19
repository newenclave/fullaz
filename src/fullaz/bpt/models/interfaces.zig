const std = @import("std");
const interfaces = @import("../../interfaces.zig");

const requiresFnSignature = interfaces.requiresFnSignature;
const requiresFnReturnsError = interfaces.requiresFnReturnsAnyError;
const requiresErrorDeclaration = interfaces.requiresErrorDeclaration;
const requiresTypeDeclaration = interfaces.requiresTypeDeclaration;

pub fn requireStorageManager(comptime T: type) void {
    requiresTypeDeclaration(T, "PageId");
    requiresErrorDeclaration(T, "Error");
    requiresFnSignature(T, "getRoot", fn (*const T) ?T.PageId);
    requiresFnReturnsError(T, "setRoot", &.{?T.PageId}, void);
    requiresFnSignature(T, "hasRoot", fn (*const T) bool);
    requiresFnReturnsError(T, "destroyPage", &.{T.PageId}, void);
}

pub fn assertModelAccessor(comptime Model: type) void {
    const A = Model.AccessorType;
    const Error = Model.Error;
    const NodeIdType = Model.NodeIdType;
    const LeafType = Model.LeafType;
    const InodeType = Model.InodeType;
    const KeyBorrowType = Model.KeyBorrowType;

    requiresFnSignature(A, "getRoot", fn (*const A) ?NodeIdType);
    requiresFnReturnsError(A, "setRoot", &.{?NodeIdType}, void);
    //requiresFnSignature(A, "setRoot", fn (*A, ?NodeIdType) Error!void);
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

pub fn assertInode(comptime Model: type) void {
    _ = Model;
}

pub fn assertLeaf(comptime Model: type) void {
    _ = Model;
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
