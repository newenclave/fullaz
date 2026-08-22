const interfaces = @import("../../../contracts/interfaces.zig");

const requiresTypeDeclaration = interfaces.requiresTypeDeclaration;
const requiresErrorDeclaration = interfaces.requiresErrorDeclaration;
const requiresFnSignature = interfaces.requiresFnSignature;
const requiresFnReturnsAnyError = interfaces.requiresFnReturnsAnyError;

pub fn assertModel(comptime M: type) void {
    requiresTypeDeclaration(M, "Pid");
    requiresTypeDeclaration(M, "Size");
    requiresErrorDeclaration(M, "Error");

    const Pid = M.Pid;
    const Size = M.Size;
    const Error = M.Error;

    requiresFnSignature(M, "find", fn (*M, Size) Error!?Pid);
    requiresFnSignature(M, "add", fn (*M, Pid, Size) Error!void);
    requiresFnSignature(M, "update", fn (*M, Pid, Size) Error!void);
    requiresFnSignature(M, "remove", fn (*M, Pid) Error!void);
}

/// Maps the FSM's u16 free-space value to a persistent slab-root class.
pub fn assertSizePolicy(comptime P: type) void {
    requiresTypeDeclaration(P, "SizeClass");
    if (P.SizeClass != u16) {
        @compileError(@typeName(P) ++ ".SizeClass must be u16");
    }

    requiresFnSignature(P, "getSizeClass", fn (*const P, u16) u16);
    requiresFnSignature(P, "count", fn (*const P) usize);
}

/// Owns persistent slab-chain roots and reclaims unlinked slab pages.
pub fn assertSlabStorageManager(comptime M: type, comptime Pid: type) void {
    requiresErrorDeclaration(M, "Error");
    requiresFnReturnsAnyError(M, "getSizeClassRoot", &.{u16}, ?Pid);
    requiresFnReturnsAnyError(M, "setSizeClassRoot", &.{ u16, ?Pid }, void);
    requiresFnReturnsAnyError(M, "destroyPage", &.{Pid}, void);
}
