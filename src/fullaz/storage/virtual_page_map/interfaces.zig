const interfaces = @import("../../contracts/interfaces.zig");

const requiresErrorDeclaration = interfaces.requiresErrorDeclaration;
const requiresFnSignature = interfaces.requiresFnSignature;
const requiresTypeDeclaration = interfaces.requiresTypeDeclaration;

/// A state lease owns a stable state-memory view until `deinit()`.
///
/// ```zig
/// const StateLease = struct {
///     pub const Error = error{};
///
///     pub fn data(_: *const StateLease) Error![]const u8 { return &.{}; }
///     pub fn dataMut(_: *StateLease) Error![]u8 { return &.{}; }
///     pub fn deinit(_: *StateLease) void {}
/// };
/// comptime assertStateLease(StateLease);
/// ```
pub fn assertStateLease(comptime StateLeaseT: type) void {
    requiresErrorDeclaration(StateLeaseT, "Error");
    const Error = StateLeaseT.Error;
    requiresFnSignature(StateLeaseT, "data", fn (*const StateLeaseT) Error![]const u8);
    requiresFnSignature(StateLeaseT, "dataMut", fn (*StateLeaseT) Error![]u8);
    requiresFnSignature(StateLeaseT, "deinit", fn (*StateLeaseT) void);
}

/// A paged virtual-page-map manager owns external state storage and page-release policy.
///
/// ```zig
/// const Manager = struct {
///     pub const PageId = u32;
///     pub const Error = error{};
///     pub const StateLeaseType = StateLease;
///
///     pub fn state(_: *Manager) Error!StateLeaseType { return .{}; }
///     pub fn destroyPage(_: *Manager, _: PageId) Error!void {}
/// };
/// comptime assertPagedStorageManager(Manager, u32);
/// ```
pub fn assertPagedStorageManager(
    comptime StorageManagerT: type,
    comptime PhysicalPageIdT: type,
) void {
    requiresErrorDeclaration(StorageManagerT, "Error");
    requiresTypeDeclaration(StorageManagerT, "PageId");
    requiresTypeDeclaration(StorageManagerT, "StateLeaseType");

    const Error = StorageManagerT.Error;
    const StateLeaseType = StorageManagerT.StateLeaseType;
    if (StorageManagerT.PageId != PhysicalPageIdT) {
        @compileError("VirtualPageMap storage manager PageId must match the physical page ID type");
    }
    assertStateLease(StateLeaseType);
    requiresFnSignature(StorageManagerT, "state", fn (*StorageManagerT) Error!StateLeaseType);
    requiresFnSignature(StorageManagerT, "destroyPage", fn (*StorageManagerT, PhysicalPageIdT) Error!void);
}
