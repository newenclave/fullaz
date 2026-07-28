const std = @import("std");
const contracts = @import("../../../contracts/contracts.zig");
const interfaces = @import("../../../contracts/interfaces.zig");

const requiresFnSignature = interfaces.requiresFnSignature;
const requiresErrorDeclaration = interfaces.requiresErrorDeclaration;
const requiresTypeDeclaration = interfaces.requiresTypeDeclaration;

pub const requiresStorageManager = contracts.storage_manager.requiresStorageManager;
pub const requiresPageCache = contracts.page_cache.requiresPageCache;

pub fn assertBox(comptime K: type) void {
    requiresTypeDeclaration(K, "Coord");
    requiresTypeDeclaration(K, "Point");

    const Coord = K.Coord;
    const Point = K.Point;

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

pub fn assertModel(comptime M: type) void {
    // requiresTypeDeclaration(M, "NodeId");
    // requiresTypeDeclaration(M, "Node");
    requiresTypeDeclaration(M, "Box");
    //    requiresTypeDeclaration(M, "Accessor");

    // const NodeId = M.NodeId;
    // const Node = M.Node;
    const Box = M.Box;
    const Accessor = M.Accessor;

    assertBox(Box);
    //    assertNode(Node);

    requiresFnSignature(M, "getAccessor", fn (*const M) *Accessor);
}
