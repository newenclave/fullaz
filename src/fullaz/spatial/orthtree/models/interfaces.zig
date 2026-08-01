const std = @import("std");
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
    requiresFnSignature(K, "containsBox", fn (*const K, *const K) bool);
    requiresFnSignature(K, "overlaps", fn (*const K, *const K) bool);
}

pub fn assertNode(comptime N: type) void {
    requiresTypeDeclaration(N, "Id");
    requiresTypeDeclaration(N, "Box");

    const Id = N.Id;
    const Box = N.Box;
    _ = Id;
    _ = Box;

    requiresFnSignature(N, "size", fn (*const N) usize);
    requiresFnSignature(N, "isLeaf", fn (*const N) bool);
}

pub fn assertEntry(comptime E: type) void {
    requiresTypeDeclaration(E, "Box");
    requiresTypeDeclaration(E, "ValueOut");
    requiresTypeDeclaration(E, "ValueBorrow");

    const Box = E.Box;
    const ValueOut = E.ValueOut;
    const ValueBorrow = E.ValueBorrow;

    requiresFnSignature(E, "box", fn (*const E) Box);
    requiresFnSignature(E, "value", fn (*const E) ValueOut);
    requiresFnSignature(E, "valueBorrow", fn (*const E) ValueBorrow);
}

pub fn assertAccessor(comptime A: type) void {
    _ = A;
    // requiresTypeDeclaration(A, "Node");
    // requiresTypeDeclaration(A, "Entry");

    // const Node = A.Node;
    // const Entry = A.Entry;

    // assertNode(Node);
    // assertEntry(Entry);

    // requiresFnSignature(A, "getNode", fn (*const A, Node.Id) ?*Node);
    // requiresFnSignature(A, "getEntry", fn (*const A, usize) ?*Entry);
}

pub fn assertModel(comptime M: type) void {
    // requiresTypeDeclaration(M, "NodeId");
    // requiresTypeDeclaration(M, "Node");
    requiresTypeDeclaration(M, "Box");
    requiresTypeDeclaration(M, "Accessor");
    requiresTypeDeclaration(M, "Entry");
    requiresTypeDeclaration(M, "Node");
    requiresTypeDeclaration(M, "ValueIn");
    requiresTypeDeclaration(M, "ValueBorrow");

    //    requiresTypeDeclaration(M, "Accessor");

    // const NodeId = M.NodeId;
    // const Node = M.Node;
    const Box = M.Box;
    const Accessor = M.Accessor;
    const ValueIn = M.ValueIn;
    const ValueBorrow = M.ValueBorrow;
    const Error = M.Error;

    assertBox(Box);
    assertAccessor(Accessor);
    assertNode(M.Node);
    assertEntry(M.Entry);

    //    assertNode(Node);

    requiresFnSignature(M, "getAccessor", fn (*M) *Accessor);
    requiresFnSignature(M, "valueBorrowAsIn", fn (*M, *const ValueBorrow) ValueIn);
    requiresFnSignature(M, "finalizeBorrowValue", fn (*M, *ValueBorrow) Error!void);
    requiresFnSignature(M, "deinitBorrowValue", fn (*M, *ValueBorrow) void);
}
