const std = @import("std");
const interfaces = @import("interfaces.zig");

const requiresFnSignature = interfaces.requiresFnSignature;
const requiresErrorDeclaration = interfaces.requiresErrorDeclaration;
const requiresTypeDeclaration = interfaces.requiresTypeDeclaration;

pub fn requiresHandle(comptime T: type) void {
    requiresErrorDeclaration(T, "Error");
    requiresTypeDeclaration(T, "Pid");
    const Error = T.Error;
    const Pid = T.Pid;
    requiresFnSignature(T, "markDirty", fn (*T) Error!void);
    requiresFnSignature(T, "pid", fn (*const T) Error!Pid);
    requiresFnSignature(T, "getData", fn (*const T) Error![]const u8);
    requiresFnSignature(T, "getDataMut", fn (*T) Error![]u8);
    requiresFnSignature(T, "clone", fn (*const T) Error!T);
    requiresFnSignature(T, "take", fn (*T) Error!T);
}

pub fn requiresPageCache(comptime T: type) void {
    requiresErrorDeclaration(T, "Error");
    requiresTypeDeclaration(T, "Handle");
    requiresTypeDeclaration(T, "Pid");
    const Error = T.Error;
    const Handle = T.Handle;

    requiresHandle(Handle);

    const Pid = T.Pid;
    if (Pid != Handle.Pid) {
        @compileError("PageCache.Handle.Pid must be the same as PageCache.Pid");
    }

    requiresFnSignature(T, "getTemporaryPage", fn (*T) Error!Handle);
    requiresFnSignature(T, "fetch", fn (*T, Pid) Error!Handle);
    requiresFnSignature(T, "create", fn (*T) Error!Handle);
    requiresFnSignature(T, "flush", fn (*T, Pid) Error!void);
    requiresFnSignature(T, "flushAll", fn (*T) Error!void);
}
