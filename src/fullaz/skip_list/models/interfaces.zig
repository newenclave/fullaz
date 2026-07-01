const std = @import("std");
const contracts = @import("../../contracts/contracts.zig");
const interfaces = @import("../../contracts/interfaces.zig");

const requiresFnSignature = interfaces.requiresFnSignature;
const requiresFnReturnsError = interfaces.requiresFnReturnsAnyError;
const requiresErrorDeclaration = interfaces.requiresErrorDeclaration;
const requiresTypeDeclaration = interfaces.requiresTypeDeclaration;

pub const requiresStorageManager = contracts.storage_manager.requiresStorageManager;
pub const requiresPageCache = contracts.page_cache.requiresPageCache;

pub fn assertModelAccessor(comptime Model: type) void {
    const A = Model.Accessor;
    assertAccessor(A);

    requiresErrorDeclaration(Model, "Error");

    const Error = Model.Error;

    requiresTypeDeclaration(Model, "Node");
    requiresTypeDeclaration(Model, "Pid");
    requiresTypeDeclaration(Model, "KeyIn");
    requiresTypeDeclaration(Model, "ValueIn");
    requiresTypeDeclaration(Model, "KeyOut");
    requiresTypeDeclaration(Model, "ValueOut");
    requiresTypeDeclaration(Model, "Path");

    requiresFnSignature(Model, "getMaxLevel", fn (*const Model) Error!usize);
    requiresFnSignature(Model, "getAccessor", fn (*Model) *A);

    const KeyIn = Model.KeyIn;
    requiresFnSignature(Model, "keysCompare", fn (*const Model, KeyIn, KeyIn) std.math.Order);

    const KeyOut = Model.KeyOut;
    requiresFnSignature(Model, "keyOutAsIn", fn (*const Model, KeyOut) KeyIn);

    const ValueOut = Model.ValueOut;
    const ValueIn = Model.ValueIn;
    requiresFnSignature(Model, "valueOutAsIn", fn (*const Model, ValueOut) ValueIn);
}

pub fn assertAccessor(comptime Accessor: type) void {
    const Error = Accessor.Error;

    requiresErrorDeclaration(Accessor, "Error");
    requiresTypeDeclaration(Accessor, "Path");
    requiresTypeDeclaration(Accessor, "Node");
    requiresTypeDeclaration(Accessor, "Pid");

    requiresTypeDeclaration(Accessor, "KeyIn");
    requiresTypeDeclaration(Accessor, "ValueIn");

    const Node = Accessor.Node;
    assertNode(Node);

    const KeyIn = Accessor.KeyIn;
    const ValueIn = Accessor.ValueIn;
    const Pid = Accessor.Pid;
    const Path = Accessor.Path;
    assertPath(Path);

    requiresFnSignature(Accessor, "createNode", fn (*Accessor, KeyIn, ValueIn) Error!Node);
    requiresFnSignature(Accessor, "loadNode", fn (*const Accessor, Pid) Error!Node);
    requiresFnSignature(Accessor, "deinitNode", fn (*const Accessor, *Node) void);

    requiresFnSignature(Accessor, "getRoot", fn (*const Accessor, usize) Error!?Pid);
    requiresFnSignature(Accessor, "setRoot", fn (*Accessor, usize, ?Pid) Error!void);
    requiresFnSignature(Accessor, "destroy", fn (*Accessor, Pid) void);

    requiresFnSignature(Accessor, "generateLevel", fn (*const Accessor, usize) Error!usize);
    requiresFnSignature(Accessor, "createPath", fn (*Accessor) Error!Path);
    requiresFnSignature(Accessor, "deinitPath", fn (*Accessor, *Path) void);
}

pub fn assertNode(comptime Node: type) void {
    requiresErrorDeclaration(Node, "Error");
    const Error = Node.Error;

    requiresTypeDeclaration(Node, "KeyIn");
    requiresTypeDeclaration(Node, "ValueIn");
    requiresTypeDeclaration(Node, "KeyOut");
    requiresTypeDeclaration(Node, "ValueOut");
    requiresTypeDeclaration(Node, "Pid");

    const KeyOut = Node.KeyOut;
    const ValueOut = Node.ValueOut;
    const Pid = Node.Pid;

    requiresFnSignature(Node, "id", fn (*const Node) Pid);

    requiresFnSignature(Node, "getKey", fn (*const Node) Error!KeyOut);
    requiresFnSignature(Node, "getValue", fn (*const Node) Error!ValueOut);

    requiresFnSignature(Node, "getPrev", fn (*const Node, usize) Error!?Pid);
    requiresFnSignature(Node, "getNext", fn (*const Node, usize) Error!?Pid);
    requiresFnSignature(Node, "setPrev", fn (*Node, usize, ?Pid) Error!void);
    requiresFnSignature(Node, "setNext", fn (*Node, usize, ?Pid) Error!void);

    requiresFnSignature(Node, "getLevel", fn (*const Node) Error!usize);
}

pub fn assertPath(comptime Path: type) void {
    requiresTypeDeclaration(Path, "Pid");
    requiresErrorDeclaration(Path, "Error");

    const Pid = Path.Pid;
    const Error = Path.Error;

    requiresFnSignature(Path, "get", fn (*const Path, usize) Error!?Pid);
    requiresFnSignature(Path, "set", fn (*Path, usize, ?Pid) Error!void);
}
