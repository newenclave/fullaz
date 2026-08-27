const interfaces = @import("../../contracts/interfaces.zig");

const requiresErrorDeclaration = interfaces.requiresErrorDeclaration;
const requiresFnSignature = interfaces.requiresFnSignature;
const requiresTypeDeclaration = interfaces.requiresTypeDeclaration;

/// A split key must expose its digit type and indexed digit access.
pub fn assertSplitKey(comptime SplitKeyT: type) void {
    requiresTypeDeclaration(SplitKeyT, "KeyDigitType");
    const KeyDigitType = SplitKeyT.KeyDigitType;

    requiresFnSignature(SplitKeyT, "size", fn (*const SplitKeyT) usize);
    requiresFnSignature(SplitKeyT, "empty", fn (*const SplitKeyT) bool);
    requiresFnSignature(SplitKeyT, "get", fn (*const SplitKeyT, usize) KeyDigitType);
}

/// A radix leaf must provide value and parent-link operations.
pub fn assertLeaf(comptime ModelT: type) void {
    const LeafType = ModelT.LeafType;
    const Error = ModelT.Error;
    const KeyInType = ModelT.KeyInType;
    const NodeIdType = ModelT.NodeIdType;
    const ValueInType = ModelT.ValueInType;
    const ValueOutType = ModelT.ValueOutType;

    requiresErrorDeclaration(LeafType, "Error");
    requiresFnSignature(LeafType, "id", fn (*const LeafType) NodeIdType);
    requiresFnSignature(LeafType, "size", fn (*const LeafType) Error!usize);
    requiresFnSignature(LeafType, "capacity", fn (*const LeafType) Error!usize);
    requiresFnSignature(LeafType, "set", fn (*LeafType, KeyInType, ValueInType) Error!void);
    requiresFnSignature(LeafType, "get", fn (*const LeafType, KeyInType) Error!ValueOutType);
    requiresFnSignature(LeafType, "free", fn (*LeafType, KeyInType) Error!void);
    requiresFnSignature(LeafType, "isSet", fn (*const LeafType, KeyInType) Error!bool);
    requiresFnSignature(LeafType, "getFirstFree", fn (*const LeafType) Error!?KeyInType);
    requiresFnSignature(LeafType, "isInFree", fn (*const LeafType) Error!bool);
    requiresFnSignature(LeafType, "setParent", fn (*LeafType, ?NodeIdType) Error!void);
    requiresFnSignature(LeafType, "getParent", fn (*const LeafType) Error!?NodeIdType);
    requiresFnSignature(LeafType, "setParentQuotient", fn (*LeafType, KeyInType) Error!void);
    requiresFnSignature(LeafType, "getParentQuotient", fn (*const LeafType) Error!KeyInType);
    requiresFnSignature(LeafType, "setParentId", fn (*LeafType, KeyInType) Error!void);
    requiresFnSignature(LeafType, "getParentId", fn (*const LeafType) Error!KeyInType);
}

/// A radix inode must provide child and parent-link operations.
pub fn assertInode(comptime ModelT: type) void {
    const InodeType = ModelT.InodeType;
    const Error = ModelT.Error;
    const KeyInType = ModelT.KeyInType;
    const NodeIdType = ModelT.NodeIdType;

    requiresErrorDeclaration(InodeType, "Error");
    requiresFnSignature(InodeType, "id", fn (*const InodeType) NodeIdType);
    requiresFnSignature(InodeType, "size", fn (*const InodeType) Error!usize);
    requiresFnSignature(InodeType, "capacity", fn (*const InodeType) Error!usize);
    requiresFnSignature(InodeType, "set", fn (*InodeType, KeyInType, NodeIdType) Error!void);
    requiresFnSignature(InodeType, "get", fn (*const InodeType, KeyInType) Error!NodeIdType);
    requiresFnSignature(InodeType, "free", fn (*InodeType, KeyInType) Error!void);
    requiresFnSignature(InodeType, "isSet", fn (*const InodeType, KeyInType) Error!bool);
    requiresFnSignature(InodeType, "setParent", fn (*InodeType, ?NodeIdType) Error!void);
    requiresFnSignature(InodeType, "getParent", fn (*const InodeType) Error!?NodeIdType);
    requiresFnSignature(InodeType, "setParentQuotient", fn (*InodeType, KeyInType) Error!void);
    requiresFnSignature(InodeType, "getParentQuotient", fn (*const InodeType) Error!KeyInType);
    requiresFnSignature(InodeType, "setParentId", fn (*InodeType, KeyInType) Error!void);
    requiresFnSignature(InodeType, "getParentId", fn (*const InodeType) Error!KeyInType);
    requiresFnSignature(InodeType, "setLevel", fn (*InodeType, usize) Error!void);
    requiresFnSignature(InodeType, "getLevel", fn (*const InodeType) Error!usize);
}

/// A radix accessor owns node loading, root management, and key splitting.
pub fn assertAccessor(comptime ModelT: type) void {
    const AccessorType = ModelT.AccessorType;
    const Error = ModelT.Error;
    const InodeType = ModelT.InodeType;
    const LeafType = ModelT.LeafType;
    const KeyInType = ModelT.KeyInType;
    const NodeIdType = ModelT.NodeIdType;
    const SplitKeyType = ModelT.SplitKeyType;

    requiresErrorDeclaration(AccessorType, "Error");
    assertSplitKey(SplitKeyType);

    requiresFnSignature(AccessorType, "getRoot", fn (*const AccessorType) Error!?NodeIdType);
    requiresFnSignature(AccessorType, "setRoot", fn (*AccessorType, ?NodeIdType) Error!void);
    requiresFnSignature(AccessorType, "getRootLevel", fn (*const AccessorType) Error!?usize);
    requiresFnSignature(AccessorType, "destroy", fn (*AccessorType, NodeIdType) Error!void);
    requiresFnSignature(AccessorType, "isLeaf", fn (*const AccessorType, NodeIdType) Error!bool);
    requiresFnSignature(AccessorType, "createLeaf", fn (*AccessorType) Error!LeafType);
    requiresFnSignature(AccessorType, "loadLeaf", fn (*AccessorType, NodeIdType) Error!LeafType);
    requiresFnSignature(AccessorType, "deinitLeaf", fn (*AccessorType, *LeafType) void);
    requiresFnSignature(AccessorType, "getFreeLeaf", fn (*AccessorType) Error!?LeafType);
    requiresFnSignature(AccessorType, "addFreeLeaf", fn (*AccessorType, *LeafType) Error!void);
    requiresFnSignature(AccessorType, "removeFreeLeaf", fn (*AccessorType, NodeIdType) Error!void);
    requiresFnSignature(AccessorType, "createInode", fn (*AccessorType) Error!InodeType);
    requiresFnSignature(AccessorType, "loadInode", fn (*AccessorType, NodeIdType) Error!InodeType);
    requiresFnSignature(AccessorType, "deinitInode", fn (*AccessorType, *InodeType) void);
    requiresFnSignature(AccessorType, "splitKey", fn (*const AccessorType, KeyInType) Error!SplitKeyType);
    requiresFnSignature(AccessorType, "deinitSplitKey", fn (*AccessorType, *SplitKeyType) void);
}

/// A paged Radix storage manager additionally owns the free-leaf-list root.
pub fn assertFreeLeafStorageManager(comptime StorageManagerT: type, comptime PageIdT: type) void {
    requiresErrorDeclaration(StorageManagerT, "Error");
    const Error = StorageManagerT.Error;
    requiresFnSignature(StorageManagerT, "getFreeLeafRoot", fn (*const StorageManagerT) ?PageIdT);
    requiresFnSignature(StorageManagerT, "setFreeLeafRoot", fn (*StorageManagerT, ?PageIdT) Error!void);
}

/// A radix model exposes the types and accessor required by 'Tree'.
///
/// ```zig
/// const Model = struct {
///     pub const AccessorType = Accessor;
///     pub const Error = error{};
///     pub fn accessor(self: *Model) *AccessorType { return &self.accessor_state; }
/// };
/// comptime assertModel(Model);
/// ```
pub fn assertModel(comptime ModelT: type) void {
    requiresErrorDeclaration(ModelT, "Error");
    requiresTypeDeclaration(ModelT, "NodeIdType");
    requiresTypeDeclaration(ModelT, "KeyInType");
    requiresTypeDeclaration(ModelT, "KeyOutType");
    requiresTypeDeclaration(ModelT, "ValueInType");
    requiresTypeDeclaration(ModelT, "ValueOutType");
    requiresTypeDeclaration(ModelT, "LeafType");
    requiresTypeDeclaration(ModelT, "InodeType");
    requiresTypeDeclaration(ModelT, "SplitKeyType");
    requiresTypeDeclaration(ModelT, "AccessorType");
    requiresTypeDeclaration(ModelT, "Settings");

    assertLeaf(ModelT);
    assertInode(ModelT);
    assertAccessor(ModelT);

    requiresFnSignature(ModelT, "accessor", fn (*ModelT) *ModelT.AccessorType);
    requiresFnSignature(ModelT, "getSettings", fn (*const ModelT) *const ModelT.Settings);
}
