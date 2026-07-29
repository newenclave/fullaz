const std = @import("std");
const contracts = @import("../../../contracts/contracts.zig");
const interfaces = @import("../../../contracts/interfaces.zig");

const requiresFnSignature = interfaces.requiresFnSignature;
const requiresErrorDeclaration = interfaces.requiresErrorDeclaration;
const requiresTypeDeclaration = interfaces.requiresTypeDeclaration;
const requiresValueDeclaration = interfaces.requiresValueDeclaration;

pub fn assertBox(comptime K: type) void {
    requiresTypeDeclaration(K, "Coord");
    requiresTypeDeclaration(K, "Point");
    requiresValueDeclaration(K, "dimension");

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
    requiresTypeDeclaration(E, "Value");

    const Box = E.Box;
    const Value = E.Value;

    requiresFnSignature(E, "getBox", fn (*const E) Box);
    requiresFnSignature(E, "getData", fn (*const E) Value);
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

    //    requiresTypeDeclaration(M, "Accessor");

    // const NodeId = M.NodeId;
    // const Node = M.Node;
    const Box = M.Box;
    const Accessor = M.Accessor;

    assertBox(Box);
    assertAccessor(Accessor);
    assertNode(M.Node);
    assertEntry(M.Entry);

    //    assertNode(Node);

    requiresFnSignature(M, "getAccessor", fn (*M) *Accessor);
}
