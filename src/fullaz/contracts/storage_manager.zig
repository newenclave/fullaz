const std = @import("std");
const interfaces = @import("interfaces.zig");

const requiresFnSignature = interfaces.requiresFnSignature;
const requiresErrorDeclaration = interfaces.requiresErrorDeclaration;
const requiresTypeDeclaration = interfaces.requiresTypeDeclaration;

pub fn requiresStorageManager(comptime T: type) void {
    requiresErrorDeclaration(T, "Error");
    const Error = T.Error;
    requiresTypeDeclaration(T, "PageId");
    requiresFnSignature(T, "getRoot", fn (*const T) ?T.PageId);
    requiresFnSignature(T, "setRoot", fn (*T, ?T.PageId) Error!void);
    requiresFnSignature(T, "hasRoot", fn (*const T) bool);
    requiresFnSignature(T, "destroyPage", fn (*T, T.PageId) Error!void);
}
