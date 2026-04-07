const contracts = @import("../../contracts/contracts.zig");

const std = @import("std");
const interfaces = @import("interfaces.zig");

const requiresFnSignature = contracts.interfaces.requiresFnSignature;
const requiresErrorDeclaration = contracts.interfaces.requiresErrorDeclaration;
const requiresTypeDeclaration = contracts.interfaces.requiresTypeDeclaration;

pub fn requiresStorageManager(comptime T: type) void {
    requiresErrorDeclaration(T, "Error");
    const Error = T.Error;
    requiresTypeDeclaration(T, "PageId");
    requiresTypeDeclaration(T, "Size");

    requiresFnSignature(T, "getTotalSize", fn (*const T) Error!T.Size);
    requiresFnSignature(T, "setTotalSize", fn (*T, T.Size) Error!void);

    requiresFnSignature(T, "getFirst", fn (*const T) Error!?T.PageId);
    requiresFnSignature(T, "getLast", fn (*const T) Error!?T.PageId);

    requiresFnSignature(T, "setFirst", fn (*T, ?T.PageId) Error!void);
    requiresFnSignature(T, "setLast", fn (*T, ?T.PageId) Error!void);

    requiresFnSignature(T, "destroyPage", fn (*T, T.PageId) Error!void);
}
