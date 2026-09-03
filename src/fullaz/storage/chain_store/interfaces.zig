const contracts = @import("../../contracts/contracts.zig");

const requiresTypeDeclaration = contracts.interfaces.requiresTypeDeclaration;

pub fn requiresStorageManager(comptime StorageManagerT: type, comptime PageIdT: type) void {
    contracts.storage_manager.assertPagedStorageManager(StorageManagerT, PageIdT);
    requiresTypeDeclaration(StorageManagerT, "Size");
}
