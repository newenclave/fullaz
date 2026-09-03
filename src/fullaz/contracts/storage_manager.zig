const std = @import("std");
const interfaces = @import("interfaces.zig");

const requiresFnSignature = interfaces.requiresFnSignature;
const requiresErrorDeclaration = interfaces.requiresErrorDeclaration;
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
///     pub fn finish(_: *StateLease) void {}
/// };
/// comptime assertStateLease(StateLease);
/// ```
pub fn assertStateLease(comptime StateLeaseT: type) void {
    requiresErrorDeclaration(StateLeaseT, "Error");
    const Error = StateLeaseT.Error;
    requiresFnSignature(StateLeaseT, "data", fn (*const StateLeaseT) Error![]const u8);
    requiresFnSignature(StateLeaseT, "dataMut", fn (*StateLeaseT) Error![]u8);
    requiresFnSignature(StateLeaseT, "deinit", fn (*StateLeaseT) void);
    requiresFnSignature(StateLeaseT, "finish", fn (*StateLeaseT) void);
}

/// A storage manager provides leased access to its exact durable state bytes.
///
/// ```zig
/// const Manager = struct {
///     pub const Error = error{};
///     pub const StateLeaseType = StateLease;
///
///     pub fn state(_: *Manager) Error!StateLeaseType { return .{}; }
/// };
/// comptime assertStorageManager(Manager);
/// ```
pub fn assertStorageManager(comptime StorageManagerT: type) void {
    requiresErrorDeclaration(StorageManagerT, "Error");
    requiresTypeDeclaration(StorageManagerT, "StateLeaseType");

    const Error = StorageManagerT.Error;
    const StateLeaseType = StorageManagerT.StateLeaseType;
    assertStateLease(StateLeaseType);
    requiresFnSignature(StorageManagerT, "state", fn (*StorageManagerT) Error!StateLeaseType);
}

/// A paged storage manager owns external state storage and page-release policy.
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
    comptime PageIdT: type,
) void {
    assertStorageManager(StorageManagerT);
    requiresTypeDeclaration(StorageManagerT, "PageId");

    const Error = StorageManagerT.Error;
    if (StorageManagerT.PageId != PageIdT) {
        @compileError("Paged storage manager PageId must match the requested page ID type");
    }
    requiresFnSignature(StorageManagerT, "destroyPage", fn (*StorageManagerT, PageIdT) Error!void);
}
