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
