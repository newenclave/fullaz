const interfaces = @import("../../contracts/interfaces.zig");

const requiresErrorDeclaration = interfaces.requiresErrorDeclaration;
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

pub fn assertPidPolicy(comptime PolicyT: type, comptime PageIdT: type) void {
    if (!@hasDecl(PolicyT, "PageId")) {
        @compileError("PidPolicy missing PageId");
    }
    if (PolicyT.PageId != PageIdT) {
        @compileError("PidPolicy.PageId must match PageCache.Pid");
    }
    if (!@hasDecl(PolicyT, "RemapContextType")) {
        @compileError("PidPolicy missing RemapContextType");
    }
    if (!@hasDecl(PolicyT, "init")) {
        @compileError("PidPolicy missing init");
    }

    requiresErrorDeclaration(PolicyT, "Error");
    const Error = PolicyT.Error;
    const RemapContextType = PolicyT.RemapContextType;
    requiresFnSignature(PolicyT, "init", fn () PolicyT);
    requiresFnSignature(
        PolicyT,
        "prepareRemap",
        fn (*PolicyT, RemapContextType, PageIdT, PageIdT) Error!void,
    );
    requiresFnSignature(PolicyT, "discard", fn (*PolicyT) void);
    requiresFnSignature(PolicyT, "written", fn (*PolicyT) void);
}

pub fn assertVirtualWritePolicy(comptime PolicyT: type, comptime ContextT: type) void {
    if (!@hasDecl(PolicyT, "WriteBatch")) {
        @compileError("Virtual write policy missing WriteBatch");
    }
    requiresErrorDeclaration(PolicyT, "Error");

    const Error = PolicyT.Error;
    const WriteBatch = PolicyT.WriteBatch;
    requiresFnSignature(PolicyT, "deinit", fn (*PolicyT) void);
    requiresFnSignature(
        PolicyT,
        "begin",
        fn (*PolicyT, ContextT.CacheRefs, u64) Error!WriteBatch,
    );
    requiresFnSignature(
        PolicyT,
        "prepareCreate",
        fn (*PolicyT, ContextT.CacheRefs) Error!void,
    );
    requiresFnSignature(
        PolicyT,
        "created",
        fn (*PolicyT, ContextT.HandleTarget) void,
    );
    requiresFnSignature(
        PolicyT,
        "prepareHandleWrite",
        fn (*PolicyT, ContextT.HandleTarget) Error!void,
    );
    requiresFnSignature(
        PolicyT,
        "prepareLayoutWrite",
        fn (*PolicyT, ContextT.LayoutTarget) Error!void,
    );
    requiresFnSignature(WriteBatch, "commit", fn (*WriteBatch) void);
    requiresFnSignature(WriteBatch, "discard", fn (*WriteBatch) void);
}
