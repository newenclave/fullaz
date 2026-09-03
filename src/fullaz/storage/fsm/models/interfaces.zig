const interfaces = @import("../../../contracts/interfaces.zig");

const requiresTypeDeclaration = interfaces.requiresTypeDeclaration;
const requiresErrorDeclaration = interfaces.requiresErrorDeclaration;
const requiresFnSignature = interfaces.requiresFnSignature;

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
    if (!@hasDecl(P, "maximum_class_count")) {
        @compileError(@typeName(P) ++ " must declare maximum_class_count");
    }
    if (P.SizeClass != u16) {
        @compileError(@typeName(P) ++ ".SizeClass must be u16");
    }
    const maximum_class_count: usize = P.maximum_class_count;
    if (maximum_class_count == 0 or
        maximum_class_count > @as(usize, @import("std").math.maxInt(P.SizeClass)) + 1)
    {
        @compileError(@typeName(P) ++ ".maximum_class_count is invalid");
    }

    requiresFnSignature(P, "getSizeClass", fn (*const P, u16) u16);
    requiresFnSignature(P, "count", fn (*const P) usize);
}
