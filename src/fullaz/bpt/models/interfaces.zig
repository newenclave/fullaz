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

pub fn assertModelAccessor(comptime T: type) void {
    _ = T;
}

pub fn assertLeaf(comptime T: type) void {
    _ = T;
}

pub fn assertInode(comptime T: type) void {
    _ = T;
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
    assertLeaf(T.LeafType);

    requiresTypeDeclaration(T, "InodeType");
    assertInode(T.InodeType);

    requiresTypeDeclaration(T, "AccessorType");
    assertModelAccessor(T.AccessorType);

    // calls:
    requiresFnSignature(T, "getAccessor", fn (*T) *T.AccessorType);
    requiresFnSignature(T, "keyBorrowAsLike", fn (*const T, *const T.KeyBorrowType) T.KeyLikeType);
    requiresFnSignature(T, "keyOutAsLike", fn (*const T, T.KeyOutType) T.KeyLikeType);
    requiresFnSignature(T, "valueOutAsIn", fn (*const T, T.ValueOutType) T.ValueInType);
    requiresFnSignature(T, "isValidId", fn (*const T, ?T.NodeIdType) bool);
}
