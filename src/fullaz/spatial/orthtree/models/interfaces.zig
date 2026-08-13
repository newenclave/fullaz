const contracts = @import("../../../contracts/contracts.zig");
const interfaces = @import("../../../contracts/interfaces.zig");

const requiresFnSignature = interfaces.requiresFnSignature;
const requiresErrorDeclaration = interfaces.requiresErrorDeclaration;
const requiresTypeDeclaration = interfaces.requiresTypeDeclaration;
const requiresField = interfaces.requiresField;

pub fn assertBox(comptime K: type) void {
    requiresTypeDeclaration(K, "Coord");
    requiresTypeDeclaration(K, "Point");
    requiresField(K, "dimension");

    const Coord = K.Coord;
    const Point = K.Point;

    requiresFnSignature(K, "create", fn (Point, Point) K);
    requiresFnSignature(K, "getLowAxis", fn (*const K, usize) Coord);
    requiresFnSignature(K, "getHighAxis", fn (*const K, usize) Coord);
    requiresFnSignature(K, "center", fn (*const K) Point);
    requiresFnSignature(K, "containsBox", fn (*const K, *const K) bool);
    requiresFnSignature(K, "contains", fn (*const K, Point) bool);
    requiresFnSignature(K, "overlaps", fn (*const K, *const K) bool);
}

fn assertEntry(comptime M: type) void {
    const E = M.Entry;

    requiresTypeDeclaration(E, "Box");
    requiresTypeDeclaration(E, "ValueOut");

    if (E.Box != M.Box) {
        @compileError(@typeName(E) ++ ".Box must match " ++ @typeName(M) ++ ".Box");
    }
    if (E.ValueOut != M.ValueOut) {
        @compileError(@typeName(E) ++ ".ValueOut must match " ++ @typeName(M) ++ ".ValueOut");
    }

    requiresFnSignature(E, "box", fn (*const E) M.Box);
    requiresFnSignature(E, "value", fn (*const E) M.ValueOut);
}

fn assertReadIterator(comptime M: type, comptime Iterator: type) void {
    const Error = M.Error;

    requiresFnSignature(Iterator, "next", fn (*Iterator) Error!?M.Entry);
    requiresFnSignature(Iterator, "deinit", fn (*Iterator) void);
}

fn assertEntries(comptime M: type, comptime Entries: type) void {
    requiresTypeDeclaration(Entries, "Iterator");
    assertReadIterator(M, Entries.Iterator);

    requiresFnSignature(Entries, "iterator", fn (*Entries) M.Error!Entries.Iterator);
    requiresFnSignature(Entries, "deinit", fn (*Entries) void);
}

fn assertCursor(comptime M: type, comptime Cursor: type) void {
    requiresFnSignature(Cursor, "next", fn (*Cursor) M.Error!?M.Entry);
    requiresFnSignature(Cursor, "deinit", fn (*Cursor) void);
}

fn assertEntriesMut(comptime M: type, comptime EntriesMut: type) void {
    requiresTypeDeclaration(EntriesMut, "Cursor");
    assertCursor(M, EntriesMut.Cursor);

    requiresFnSignature(EntriesMut, "cursor", fn (*EntriesMut) M.Error!EntriesMut.Cursor);
    requiresFnSignature(
        EntriesMut,
        "moveCurrentTo",
        fn (*EntriesMut, *EntriesMut.Cursor, *EntriesMut) M.Error!M.Entry,
    );
    requiresFnSignature(
        EntriesMut,
        "removeCurrent",
        fn (*EntriesMut, *EntriesMut.Cursor) M.Error!M.ValueBorrow,
    );
    requiresFnSignature(
        EntriesMut,
        "markCurrentTombstone",
        fn (*EntriesMut, *EntriesMut.Cursor) M.Error!void,
    );
    requiresFnSignature(EntriesMut, "deinit", fn (*EntriesMut) void);
}

fn assertNode(comptime M: type) void {
    const N = M.Node;

    requiresTypeDeclaration(N, "Id");
    requiresTypeDeclaration(N, "Box");
    requiresTypeDeclaration(N, "Entries");
    requiresTypeDeclaration(N, "EntriesMut");
    requiresTypeDeclaration(N, "Trait");

    if (N.Id != M.NodeId) {
        @compileError(@typeName(N) ++ ".Id must match " ++ @typeName(M) ++ ".NodeId");
    }
    if (N.Box != M.Box) {
        @compileError(@typeName(N) ++ ".Box must match " ++ @typeName(M) ++ ".Box");
    }
    if (N.Trait != M.Trait) {
        @compileError(@typeName(N) ++ ".Trait must match " ++ @typeName(M) ++ ".Trait");
    }

    assertEntries(M, N.Entries);
    assertEntriesMut(M, N.EntriesMut);

    requiresFnSignature(N, "size", fn (*const N) usize);
    requiresFnSignature(N, "isLeaf", fn (*const N) bool);
    requiresFnSignature(N, "bounds", fn (*const N) M.Box);
    requiresFnSignature(N, "id", fn (*const N) M.NodeId);
    requiresFnSignature(N, "getChild", fn (*const N, usize) ?M.NodeId);
    requiresFnSignature(N, "setChild", fn (*N, usize, M.NodeId) M.Error!void);
    requiresFnSignature(N, "getParent", fn (*const N) M.Error!?M.NodeId);
    requiresFnSignature(N, "setParent", fn (*N, ?M.NodeId) M.Error!void);
    requiresFnSignature(N, "getLevel", fn (*const N) usize);
    requiresFnSignature(N, "setLevel", fn (*N, usize) M.Error!void);
    requiresFnSignature(N, "canInsertEntry", fn (*const N, M.Box, M.ValueIn) M.Error!bool);
    requiresFnSignature(N, "canSplit", fn (*const N) bool);
    requiresFnSignature(N, "beforeSplit", fn (*N) M.Error!void);
    requiresFnSignature(N, "addEntry", fn (*N, M.Box, M.ValueIn) M.Error!void);
    requiresFnSignature(N, "entries", fn (*N) M.Error!N.Entries);
    requiresFnSignature(N, "entriesMut", fn (*N) M.Error!N.EntriesMut);
    requiresFnSignature(N, "trait", fn (*const N) *const M.Trait);
    requiresFnSignature(N, "traitMut", fn (*N) M.Error!*M.Trait);
}

fn assertAccessor(comptime M: type) void {
    const A = M.AccessorType;

    requiresFnSignature(A, "getRoot", fn (*const A) ?M.NodeId);
    requiresFnSignature(A, "setRoot", fn (*A, ?M.NodeId) M.Error!void);
    requiresFnSignature(A, "createNode", fn (*A, M.Box) M.Error!M.Node);
    requiresFnSignature(A, "loadNode", fn (*A, M.NodeId) M.Error!M.Node);
    requiresFnSignature(A, "deinitNode", fn (*A, *M.Node) void);
}

pub fn assertModel(comptime M: type) void {
    requiresErrorDeclaration(M, "Error");
    requiresTypeDeclaration(M, "NodeId");
    requiresTypeDeclaration(M, "Box");
    requiresTypeDeclaration(M, "AccessorType");
    requiresTypeDeclaration(M, "Entry");
    requiresTypeDeclaration(M, "Node");
    requiresTypeDeclaration(M, "ValueIn");
    requiresTypeDeclaration(M, "ValueOut");
    requiresTypeDeclaration(M, "ValueBorrow");
    requiresTypeDeclaration(M, "Trait");

    const Box = M.Box;
    const AccessorType = M.AccessorType;
    const ValueIn = M.ValueIn;
    const ValueOut = M.ValueOut;
    const ValueBorrow = M.ValueBorrow;
    const Error = M.Error;

    assertBox(Box);
    assertEntry(M);
    assertNode(M);
    assertAccessor(M);

    requiresFnSignature(M, "accessor", fn (*M) *AccessorType);
    requiresFnSignature(M, "incrementEntriesCount", fn (*M) Error!void);
    requiresFnSignature(M, "decrementEntriesCount", fn (*M) Error!void);
    requiresFnSignature(M, "getEntriesCount", fn (*const M) Error!usize);
    requiresFnSignature(M, "valueOutAsIn", fn (*const M, ValueOut) ValueIn);
    requiresFnSignature(M, "valueBorrowAsIn", fn (*const M, *const ValueBorrow) ValueIn);
    requiresFnSignature(M, "finalizeBorrowValue", fn (*M, *ValueBorrow) Error!void);
    requiresFnSignature(M, "deinitBorrowValue", fn (*M, *ValueBorrow) void);
}

pub fn requiresLegacyPagedStorageManager(comptime T: type) void {
    contracts.storage_manager.requiresStorageManager(T);

    const Error = T.Error;
    requiresFnSignature(T, "getEntriesCount", fn (*const T) Error!usize);
    requiresFnSignature(T, "setEntriesCount", fn (*T, usize) Error!void);
}

pub fn requiresPagedStorageManager(comptime T: type, comptime ExpectedNodeId: type) void {
    requiresErrorDeclaration(T, "Error");
    requiresTypeDeclaration(T, "PageId");
    requiresTypeDeclaration(T, "NodeId");

    if (T.NodeId != ExpectedNodeId) {
        @compileError(@typeName(T) ++ ".NodeId must match the paged Orthtree NodeId");
    }

    const Error = T.Error;
    requiresFnSignature(T, "getRoot", fn (*const T) ?T.NodeId);
    requiresFnSignature(T, "setRoot", fn (*T, ?T.NodeId) Error!void);
    requiresFnSignature(T, "destroyPage", fn (*T, T.PageId) Error!void);
    requiresFnSignature(T, "getEntriesCount", fn (*const T) Error!usize);
    requiresFnSignature(T, "setEntriesCount", fn (*T, usize) Error!void);
}
