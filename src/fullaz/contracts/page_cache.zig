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

pub fn requiresTransactionalPageCache(comptime T: type) void {
    requiresPinAwarePageCache(T);
    requiresTypeDeclaration(T, "WriteBatch");
    const WriteBatch = T.WriteBatch;
    requiresFnSignature(WriteBatch, "commit", fn (*WriteBatch) T.Error!void);
    requiresFnSignature(WriteBatch, "discard", fn (*WriteBatch) T.Error!void);
    requiresFnSignature(T, "begin", fn (*T) T.Error!WriteBatch);
    requiresFnSignature(T, "transactionActive", fn (*const T) bool);
    requiresFnSignature(T, "transactionGeneration", fn (*const T) ?u64);
    requiresFnSignature(T, "markTransactionFailed", fn (*T) void);
}

pub fn requiresAppendOnlyDensePageCache(comptime T: type) void {
    requiresTransactionalPageCache(T);
    switch (@typeInfo(T.Pid)) {
        .int => |int_info| {
            if (int_info.signedness != .unsigned) {
                @compileError("Append-only dense PageCache.Pid must be unsigned");
            }
        },
        else => @compileError("Append-only dense PageCache.Pid must be an integer"),
    }
    if (!@hasDecl(T, "append_only_dense_page_ids")) {
        @compileError("PageCache must declare append_only_dense_page_ids: bool");
    }
    if (@TypeOf(T.append_only_dense_page_ids) != bool) {
        @compileError("PageCache append_only_dense_page_ids must be bool");
    }
    if (!T.append_only_dense_page_ids) {
        @compileError("PageCache must guarantee append-only dense page IDs");
    }
}
