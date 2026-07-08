const interfaces = @import("../../contracts/interfaces.zig");

const requiresFnSignature = interfaces.requiresFnSignature;

pub fn assertMemoryCachePolicy(comptime PolicyT: type, comptime FrameT: type) void {
    if (!@hasDecl(PolicyT, "init")) {
        @compileError("MemoryCachePolicy missing: " ++ @typeName(PolicyT) ++ ".init");
    }
    if (!@hasDecl(PolicyT, "deinit")) {
        @compileError("MemoryCachePolicy missing: " ++ @typeName(PolicyT) ++ ".deinit");
    }
    requiresFnSignature(PolicyT, "popFree", fn (*PolicyT) ?*FrameT);
    requiresFnSignature(PolicyT, "pushFree", fn (*PolicyT, *FrameT) void);
    requiresFnSignature(PolicyT, "selectVictim", fn (*PolicyT, bool) ?*FrameT);
    requiresFnSignature(PolicyT, "pushHead", fn (*PolicyT, *FrameT) void);
    requiresFnSignature(PolicyT, "unlink", fn (*PolicyT, *FrameT) void);
    requiresFnSignature(PolicyT, "moveToHead", fn (*PolicyT, *FrameT) void);
    requiresFnSignature(PolicyT, "framesSlice", fn (*const PolicyT) []FrameT);
}
