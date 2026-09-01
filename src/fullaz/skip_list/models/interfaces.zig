const std = @import("std");
const contracts = @import("../../contracts/contracts.zig");
const interfaces = @import("../../contracts/interfaces.zig");

const requiresFnSignature = interfaces.requiresFnSignature;
const requiresFnReturnsError = interfaces.requiresFnReturnsAnyError;
const requiresErrorDeclaration = interfaces.requiresErrorDeclaration;
const requiresTypeDeclaration = interfaces.requiresTypeDeclaration;
const StructuralMutationCoordinator = @import("../../core/core.zig").structural_mutation.StructuralMutationCoordinator;

pub const requiresStorageManager = contracts.storage_manager.requiresStorageManager;
pub const requiresPageCache = contracts.page_cache.requiresPageCache;

pub fn assertModelAccessor(comptime Model: type) void {
    const A = Model.AccessorType;
    assertAccessor(Model);

    requiresErrorDeclaration(Model, "Error");

    const Error = Model.Error;

    requiresTypeDeclaration(Model, "Node");
    requiresTypeDeclaration(Model, "Pid");
    requiresTypeDeclaration(Model, "KeyIn");
    requiresTypeDeclaration(Model, "ValueIn");
    requiresTypeDeclaration(Model, "KeyOut");
    requiresTypeDeclaration(Model, "ValueOut");
    requiresTypeDeclaration(Model, "Path");
    requiresTypeDeclaration(Model, "ValueEditorType");

    requiresFnSignature(Model, "getMaxLevel", fn (*const Model) Error!usize);
    requiresFnSignature(Model, "accessor", fn (*Model) *A);
    requiresFnSignature(Model, "structuralMutationCoordinator", fn (*Model) *StructuralMutationCoordinator);

    const KeyIn = Model.KeyIn;
    requiresFnSignature(Model, "keysCompare", fn (*const Model, KeyIn, KeyIn) std.math.Order);

    const KeyOut = Model.KeyOut;
    requiresFnSignature(Model, "keyOutAsIn", fn (*const Model, KeyOut) KeyIn);

    const ValueOut = Model.ValueOut;
    const ValueIn = Model.ValueIn;
    requiresFnSignature(Model, "valueOutAsIn", fn (*const Model, ValueOut) ValueIn);
    assertValueEditor(Model);
}

pub fn assertAccessor(comptime Model: type) void {
    const Accessor = Model.AccessorType;
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
    requiresFnSignature(Accessor, "openValueEditor", fn (*Accessor, *Node) Error!Model.ValueEditorType);
}

/// A value editor owns mutable access to one node value until finish or deinit.
///
/// A model exposes `ValueEditorType` with `ValueMutType`, `valueMut()`,
/// `finish()`, and `deinit()`; call `assertValueEditor(Model)`.
pub fn assertValueEditor(comptime Model: type) void {
    const Editor = Model.ValueEditorType;
    const Error = Editor.Error;

    requiresErrorDeclaration(Editor, "Error");
    requiresTypeDeclaration(Editor, "ValueMutType");
    requiresFnSignature(Editor, "valueMut", fn (*Editor) Error!Editor.ValueMutType);
    requiresFnSignature(Editor, "finish", fn (*Editor) Error!void);
    requiresFnSignature(Editor, "deinit", fn (*Editor) void);
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
