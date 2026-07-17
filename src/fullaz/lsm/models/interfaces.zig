const std = @import("std");
const iface = @import("../../contracts/interfaces.zig");
const Entry = @import("entry.zig").Entry;

pub fn assertKvCursor(comptime It: type) void {
    iface.requiresErrorDeclaration(It, "Error");
    const E = It.Error;
    iface.requiresFnSignature(It, "peek", fn (*const It) E!?Entry);
    iface.requiresFnSignature(It, "advance", fn (*It) E!void);
    iface.requiresFnSignature(It, "deinit", fn (*It) void);
}

pub fn assertMemtable(comptime M: type) void {
    iface.requiresErrorDeclaration(M, "Error");
    iface.requiresTypeDeclaration(M, "Iterator");

    iface.requiresTypeDeclaration(M, "KeyInType");
    iface.requiresTypeDeclaration(M, "ValueInType");
    iface.requiresTypeDeclaration(M, "ValueOutType");

    const E = M.Error;
    const It = M.Iterator;

    const KeyInType = M.KeyInType;
    const ValueInType = M.ValueInType;
    const ValueOutType = M.ValueOutType;

    iface.requiresFnSignature(M, "reset", fn (*M) E!void);
    iface.requiresFnSignature(M, "put", fn (*M, KeyInType, ValueInType) E!void);
    iface.requiresFnSignature(M, "get", fn (*const M, KeyInType) E!?ValueOutType);
    iface.requiresFnSignature(M, "byteSize", fn (*const M) usize);
    iface.requiresFnSignature(M, "count", fn (*const M) usize);
    iface.requiresFnSignature(M, "iterator", fn (*const M) E!It);
    iface.requiresFnSignature(M, "seek", fn (*const M, KeyInType) E!It);
    assertKvCursor(It);
}

// An immutable, already-flushed run. No deinit on the run itself closing a
// loaded run is the Accessor's job (loadRun/closeRun), same split bpt uses for
// LeafType/InodeType.
pub fn assertRun(comptime Model: type) void {
    const R = Model.RunType;
    iface.requiresErrorDeclaration(R, "Error");
    iface.requiresTypeDeclaration(R, "Iterator");

    const E = R.Error;
    const It = R.Iterator;

    iface.requiresFnSignature(R, "id", fn (*const R) Model.RunIdType);
    iface.requiresFnSignature(R, "byteSize", fn (*const R) usize);
    iface.requiresFnSignature(R, "count", fn (*const R) usize);
    iface.requiresFnSignature(R, "get", fn (*const R, Model.KeyInType) E!?Model.ValueEncodedType);
    iface.requiresFnSignature(R, "iterator", fn (*const R) E!It);
    iface.requiresFnSignature(R, "seek", fn (*const R, Model.KeyInType) E!It);
    assertKvCursor(It);
}

// Owns the active memtable and the newest-first list of run ids.
pub fn assertRunAccessor(comptime Model: type) void {
    const A = Model.AccessorType;
    iface.requiresErrorDeclaration(A, "Error");
    const E = A.Error;

    iface.requiresFnSignature(A, "loadActiveMemtable", fn (*A) Model.MemtableType);
    iface.requiresFnSignature(A, "deinitActiveMemtable", fn (*A, *Model.MemtableType) void);

    iface.requiresFnSignature(A, "runCount", fn (*const A) usize);
    iface.requiresFnSignature(A, "runIdAt", fn (*const A, usize) Model.RunIdType);
    iface.requiresFnSignature(A, "loadRun", fn (*A, Model.RunIdType) E!?Model.RunType);
    iface.requiresFnSignature(A, "closeRun", fn (*A, ?Model.RunType) void);
    iface.requiresFnSignature(A, "publish", fn (*A, []const Model.RunIdType, ?Model.RunIdType) E!void);

    // buildRun(self: *A, cursor: anytype) E!Model.RunIdType, so anytype cannot
    // be written as a comparable fn type
    if (!@hasDecl(A, "buildRun")) {
        @compileError("Missing declaration: " ++ @typeName(A) ++ ".buildRun");
    }
}

pub fn assertModel(comptime T: type) void {
    iface.requiresTypeDeclaration(T, "RunIdType");
    iface.requiresErrorDeclaration(T, "Error");

    iface.requiresTypeDeclaration(T, "KeyInType");
    iface.requiresTypeDeclaration(T, "ValueInType");
    iface.requiresTypeDeclaration(T, "ValueOutType");
    iface.requiresTypeDeclaration(T, "ValueEncodedType");

    iface.requiresTypeDeclaration(T, "MemtableType");
    assertMemtable(T.MemtableType);

    iface.requiresTypeDeclaration(T, "RunType");
    assertRun(T);

    iface.requiresTypeDeclaration(T, "AccessorType");
    assertRunAccessor(T);

    iface.requiresFnSignature(T, "getAccessor", fn (*T) *T.AccessorType);
}
