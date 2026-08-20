const std = @import("std");
const interfaces = @import("interfaces.zig");

const requiresFnSignature = interfaces.requiresFnSignature;
const requiresErrorDeclaration = interfaces.requiresErrorDeclaration;
const requiresTypeDeclaration = interfaces.requiresTypeDeclaration;

pub fn requiresHandle(comptime T: type) void {
    requiresErrorDeclaration(T, "Error");
    requiresTypeDeclaration(T, "Pid");
    requiresTypeDeclaration(T, "LayoutLock");
    const Error = T.Error;
    const Pid = T.Pid;
    const LayoutLock = T.LayoutLock;
    requiresFnSignature(T, "deinit", fn (*T) void);
    requiresFnSignature(T, "markDirty", fn (*T) Error!void);
    requiresFnSignature(T, "pid", fn (*const T) Error!Pid);
    requiresFnSignature(T, "data", fn (*const T) Error![]const u8);
    requiresFnSignature(T, "dataMut", fn (*T) Error![]u8);
    requiresFnSignature(T, "isLayoutLocked", fn (*const T) Error!bool);
    requiresFnSignature(T, "lockLayout", fn (*const T) Error!LayoutLock);
    requiresFnSignature(T, "clone", fn (*const T) Error!T);
    requiresFnSignature(T, "take", fn (*T) Error!T);
}

pub fn requiresPageCache(comptime T: type) void {
    requiresErrorDeclaration(T, "Error");
    requiresTypeDeclaration(T, "Handle");
    requiresTypeDeclaration(T, "Pid");
    requiresTypeDeclaration(T, "UnderlyingDevice");
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

pub fn requiresPinAwarePageCache(comptime T: type) void {
    requiresPageCache(T);
    requiresFnSignature(T, "isPinned", fn (*const T, T.Pid) bool);
}
