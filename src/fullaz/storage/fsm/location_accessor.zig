const interfaces = @import("../../contracts/interfaces.zig");

const requiresErrorDeclaration = interfaces.requiresErrorDeclaration;
const requiresFnSignature = interfaces.requiresFnSignature;
const requiresTypeDeclaration = interfaces.requiresTypeDeclaration;

pub fn assertAccessor(comptime Accessor: type) void {
    requiresTypeDeclaration(Accessor, "Location");
    requiresErrorDeclaration(Accessor, "Error");

    const Location = Accessor.Location;
    const Error = Accessor.Error;

    requiresFnSignature(Accessor, "read", fn ([]const u8) Error!?Location);
    requiresFnSignature(Accessor, "write", fn ([]u8, Location) Error!void);
    requiresFnSignature(Accessor, "clear", fn ([]u8) Error!void);
}
