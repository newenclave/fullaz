const std = @import("std");
const interfaces = @import("../../../contracts/interfaces.zig");

const requiresErrorDeclaration = interfaces.requiresErrorDeclaration;
const requiresFnSignature = interfaces.requiresFnSignature;
const requiresTypeDeclaration = interfaces.requiresTypeDeclaration;

pub const WinnerChange = enum {
    unchanged,
    changed,
};

fn assertLocation(comptime LocationT: type, comptime PageIdT: type, comptime SlotIdT: type) void {
    if (@typeInfo(LocationT) != .@"struct" or
        !@hasField(LocationT, "page_id") or
        !@hasField(LocationT, "slot_id"))
    {
        @compileError(@typeName(LocationT) ++ " must contain page_id and slot_id fields");
    }
    if (@FieldType(LocationT, "page_id") != PageIdT or
        @FieldType(LocationT, "slot_id") != SlotIdT)
    {
        @compileError(@typeName(LocationT) ++ " field types do not match the model IDs");
    }
}

fn assertLeaf(comptime ModelT: type) void {
    const Leaf = ModelT.LeafType;
    const Error = ModelT.Error;
    const NodeId = ModelT.NodeIdType;
    const KeyIn = ModelT.KeyInType;
    const KeyOut = ModelT.KeyOutType;
    const ValueIn = ModelT.ValueInType;
    const ValueOut = ModelT.ValueOutType;
    const Space = ModelT.SpaceType;

    requiresErrorDeclaration(Leaf, "Error");
    if (Leaf.Error != Error) {
        @compileError(@typeName(Leaf) ++ ".Error must match " ++ @typeName(ModelT) ++ ".Error");
    }

    requiresFnSignature(Leaf, "id", fn (*const Leaf) NodeId);
    requiresFnSignature(Leaf, "take", fn (*Leaf) Error!Leaf);
    requiresFnSignature(Leaf, "size", fn (*const Leaf) Error!usize);
    requiresFnSignature(Leaf, "getParent", fn (*const Leaf) Error!?NodeId);
    requiresFnSignature(Leaf, "setParent", fn (*Leaf, ?NodeId) Error!void);
    // KeyOut and ValueOut may borrow from Leaf. The caller keeps a taken Leaf
    // alive until both outputs are no longer used, then calls deinitLeaf().
    requiresFnSignature(Leaf, "getKey", fn (*const Leaf, usize) Error!KeyOut);
    requiresFnSignature(Leaf, "getValue", fn (*const Leaf, usize) Error!ValueOut);
    requiresFnSignature(Leaf, "canPush", fn (*const Leaf, KeyIn, ValueIn) Error!bool);
    requiresFnSignature(Leaf, "push", fn (*Leaf, KeyIn, ValueIn) Error!WinnerChange);
    requiresFnSignature(Leaf, "popTop", fn (*Leaf) Error!void);
    requiresFnSignature(Leaf, "availableAfterCompact", fn (*const Leaf) Error!Space);
    requiresFnSignature(Leaf, "usedBytes", fn (*const Leaf) Error!usize);
    requiresFnSignature(Leaf, "capacityBytes", fn (*const Leaf) Error!usize);
}

fn assertInode(comptime ModelT: type) void {
    const Inode = ModelT.InodeType;
    const Error = ModelT.Error;
    const NodeId = ModelT.NodeIdType;
    const Location = ModelT.LocationType;
    const KeyIn = ModelT.KeyInType;
    const KeyOut = ModelT.KeyOutType;

    requiresErrorDeclaration(Inode, "Error");
    if (Inode.Error != Error) {
        @compileError(@typeName(Inode) ++ ".Error must match " ++ @typeName(ModelT) ++ ".Error");
    }

    requiresFnSignature(Inode, "id", fn (*const Inode) NodeId);
    requiresFnSignature(Inode, "take", fn (*Inode) Error!Inode);
    requiresFnSignature(Inode, "size", fn (*const Inode) Error!usize);
    requiresFnSignature(Inode, "capacity", fn (*const Inode) Error!usize);
    requiresFnSignature(Inode, "getLevel", fn (*const Inode) Error!usize);
    requiresFnSignature(Inode, "getParent", fn (*const Inode) Error!?NodeId);
    requiresFnSignature(Inode, "setParent", fn (*Inode, ?NodeId) Error!void);

    requiresFnSignature(Inode, "getAvailablePrev", fn (*const Inode) Error!?NodeId);
    requiresFnSignature(Inode, "setAvailablePrev", fn (*Inode, ?NodeId) Error!void);
    requiresFnSignature(Inode, "getAvailableNext", fn (*const Inode) Error!?NodeId);
    requiresFnSignature(Inode, "setAvailableNext", fn (*Inode, ?NodeId) Error!void);
    requiresFnSignature(Inode, "isAvailableLinked", fn (*const Inode) Error!bool);
    requiresFnSignature(Inode, "setAvailableLinked", fn (*Inode, bool) Error!void);

    requiresFnSignature(Inode, "findChild", fn (*const Inode, NodeId) Error!?usize);
    requiresFnSignature(Inode, "getKey", fn (*const Inode, usize) Error!KeyOut);
    requiresFnSignature(Inode, "getChild", fn (*const Inode, usize) Error!NodeId);
    requiresFnSignature(Inode, "getWinner", fn (*const Inode, usize) Error!Location);
    requiresFnSignature(Inode, "insertChild", fn (*Inode, KeyIn, NodeId, Location) Error!WinnerChange);
    requiresFnSignature(Inode, "updateChild", fn (*Inode, usize, KeyIn, Location) Error!WinnerChange);
    requiresFnSignature(Inode, "removeChild", fn (*Inode, usize) Error!WinnerChange);
}

fn assertAccessor(comptime ModelT: type) void {
    const Accessor = ModelT.AccessorType;
    const Error = ModelT.Error;
    const NodeId = ModelT.NodeIdType;
    const Location = ModelT.LocationType;
    const Space = ModelT.SpaceType;
    const Leaf = ModelT.LeafType;
    const Inode = ModelT.InodeType;

    requiresErrorDeclaration(Accessor, "Error");
    if (Accessor.Error != Error) {
        @compileError(@typeName(Accessor) ++ ".Error must match " ++ @typeName(ModelT) ++ ".Error");
    }

    requiresFnSignature(Accessor, "getRoot", fn (*const Accessor) ?NodeId);
    requiresFnSignature(Accessor, "setRoot", fn (*Accessor, ?NodeId) Error!void);
    requiresFnSignature(Accessor, "getCachedTop", fn (*const Accessor) ?Location);
    requiresFnSignature(Accessor, "setCachedTop", fn (*Accessor, ?Location) Error!void);
    requiresFnSignature(Accessor, "getAvailableInode", fn (*const Accessor, usize) Error!?NodeId);
    requiresFnSignature(Accessor, "setAvailableInode", fn (*Accessor, usize, ?NodeId) Error!void);

    requiresFnSignature(Accessor, "createLeaf", fn (*Accessor) Error!Leaf);
    requiresFnSignature(Accessor, "createInode", fn (*Accessor, usize) Error!Inode);
    requiresFnSignature(Accessor, "loadLeaf", fn (*Accessor, NodeId) Error!?Leaf);
    requiresFnSignature(Accessor, "loadInode", fn (*Accessor, NodeId) Error!?Inode);
    requiresFnSignature(Accessor, "deinitLeaf", fn (*Accessor, ?Leaf) void);
    requiresFnSignature(Accessor, "deinitInode", fn (*Accessor, ?Inode) void);
    requiresFnSignature(Accessor, "isLeafId", fn (*Accessor, NodeId) Error!bool);
    requiresFnSignature(Accessor, "destroy", fn (*Accessor, NodeId) Error!void);

    requiresFnSignature(Accessor, "findLeaf", fn (*Accessor, Space) Error!?NodeId);
    requiresFnSignature(Accessor, "addLeafSpace", fn (*Accessor, NodeId, Space) Error!void);
    requiresFnSignature(Accessor, "updateLeafSpace", fn (*Accessor, NodeId, Space) Error!void);
    requiresFnSignature(Accessor, "removeLeafSpace", fn (*Accessor, NodeId) Error!void);
}

/// A slot-heap model supplies page-like leaves/inodes and metadata access.
///
/// ```zig
/// const Model = @import("my_slot_heap_model.zig").Model;
/// comptime {
///     _ = Model.NodeIdType;
///     _ = Model.SlotIdType;
///     _ = Model.LocationType;
///     _ = Model.LeafType;
///     _ = Model.InodeType;
///     _ = Model.AccessorType;
///     assertModel(Model);
/// }
/// ```
pub fn assertModel(comptime ModelT: type) void {
    requiresErrorDeclaration(ModelT, "Error");
    requiresTypeDeclaration(ModelT, "NodeIdType");
    requiresTypeDeclaration(ModelT, "SlotIdType");
    requiresTypeDeclaration(ModelT, "LocationType");
    requiresTypeDeclaration(ModelT, "CountType");
    requiresTypeDeclaration(ModelT, "SpaceType");
    requiresTypeDeclaration(ModelT, "KeyInType");
    requiresTypeDeclaration(ModelT, "KeyOutType");
    requiresTypeDeclaration(ModelT, "ValueInType");
    requiresTypeDeclaration(ModelT, "ValueOutType");
    requiresTypeDeclaration(ModelT, "LeafType");
    requiresTypeDeclaration(ModelT, "InodeType");
    requiresTypeDeclaration(ModelT, "AccessorType");

    assertLocation(ModelT.LocationType, ModelT.NodeIdType, ModelT.SlotIdType);
    assertLeaf(ModelT);
    assertInode(ModelT);
    assertAccessor(ModelT);

    const Error = ModelT.Error;
    requiresFnSignature(ModelT, "accessor", fn (*ModelT) *ModelT.AccessorType);
    requiresFnSignature(
        ModelT,
        "compareKeys",
        fn (*const ModelT, ModelT.KeyOutType, ModelT.KeyOutType) Error!std.math.Order,
    );
    requiresFnSignature(
        ModelT,
        "keyOutAsIn",
        fn (*const ModelT, ModelT.KeyOutType) ModelT.KeyInType,
    );
    requiresFnSignature(
        ModelT,
        "requiredLeafSpace",
        fn (*const ModelT, ModelT.KeyInType, ModelT.ValueInType) Error!ModelT.SpaceType,
    );
    requiresFnSignature(ModelT, "incrementEntriesCount", fn (*ModelT) Error!void);
    requiresFnSignature(ModelT, "decrementEntriesCount", fn (*ModelT) Error!void);
    requiresFnSignature(ModelT, "getEntriesCount", fn (*const ModelT) Error!ModelT.CountType);
}

/// Persistent slot-heap metadata includes the root, cached winner, count, and
/// one available-inode list head per tree level.
///
/// ```zig
/// const Manager = @import("heap_storage.zig").Manager;
/// const Location = struct { page_id: Manager.PageId, slot_id: u16 };
/// comptime {
///     _ = Manager.PageId;
///     _ = Manager.CountType;
///     assertPagedStorageManager(Manager, Location);
/// }
/// ```
pub fn assertPagedStorageManager(comptime ManagerT: type, comptime LocationT: type) void {
    requiresErrorDeclaration(ManagerT, "Error");
    requiresTypeDeclaration(ManagerT, "PageId");
    requiresTypeDeclaration(ManagerT, "CountType");

    if (@typeInfo(LocationT) != .@"struct" or !@hasField(LocationT, "page_id")) {
        @compileError(@typeName(LocationT) ++ " must contain a page_id field");
    }
    if (@FieldType(LocationT, "page_id") != ManagerT.PageId) {
        @compileError("Slot-heap location page ID must match the storage manager PageId");
    }

    const Error = ManagerT.Error;
    const PageId = ManagerT.PageId;
    const Count = ManagerT.CountType;
    requiresFnSignature(ManagerT, "getRoot", fn (*const ManagerT) ?PageId);
    requiresFnSignature(ManagerT, "setRoot", fn (*ManagerT, ?PageId) Error!void);
    requiresFnSignature(ManagerT, "getCachedTop", fn (*const ManagerT) ?LocationT);
    requiresFnSignature(ManagerT, "setCachedTop", fn (*ManagerT, ?LocationT) Error!void);
    requiresFnSignature(ManagerT, "getEntriesCount", fn (*const ManagerT) Error!Count);
    requiresFnSignature(ManagerT, "setEntriesCount", fn (*ManagerT, Count) Error!void);
    requiresFnSignature(ManagerT, "getAvailableInode", fn (*const ManagerT, usize) Error!?PageId);
    requiresFnSignature(ManagerT, "setAvailableInode", fn (*ManagerT, usize, ?PageId) Error!void);
    requiresFnSignature(ManagerT, "destroyPage", fn (*ManagerT, PageId) Error!void);
}
