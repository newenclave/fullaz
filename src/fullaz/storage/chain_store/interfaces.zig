const contracts = @import("../../contracts/contracts.zig");

const requiresFnSignature = contracts.interfaces.requiresFnSignature;
const requiresTypeDeclaration = contracts.interfaces.requiresTypeDeclaration;

pub fn requiresStorageManager(comptime StorageManagerT: type, comptime PageIdT: type) void {
    contracts.storage_manager.assertPagedStorageManager(StorageManagerT, PageIdT);
    requiresTypeDeclaration(StorageManagerT, "Size");
}

pub fn requiresStorageManagerIndexRoot(comptime T: type) void {
    const Error = T.Error;
    requiresFnSignature(T, "getIndexRoot", fn (*const T) ?T.PageId);
    requiresFnSignature(T, "setIndexRoot", fn (*T, ?T.PageId) Error!void);
}
