const std = @import("std");
const contract_interfaces = @import("../contracts/interfaces.zig");

const requiresErrorDeclaration = contract_interfaces.requiresErrorDeclaration;
const requiresFnSignature = contract_interfaces.requiresFnSignature;
const requiresTypeDeclaration = contract_interfaces.requiresTypeDeclaration;

/// A paged GC cache provides raw page handles inside a caller-owned transaction.
///
/// ```zig
/// const Cache = struct {
///     pub const Pid = u32;
///     pub const Error = error{};
///     pub const Handle = struct {
///         pub const Error = error{};
///         pub fn deinit(_: *@This()) void {}
///         pub fn pid(_: *const @This()) Error!Pid { unreachable }
///         pub fn data(_: *const @This()) Error![]const u8 { unreachable }
///         pub fn dataMut(_: *@This()) Error![]u8 { unreachable }
///     };
///     pub fn fetch(_: *@This(), _: Pid) Error!Handle { unreachable }
///     pub fn create(_: *@This()) Error!Handle { unreachable }
///     pub fn pageCount(_: *const @This()) usize { return 0; }
///     pub fn pageSize(_: *const @This()) usize { return 0; }
///     pub fn transactionActive(_: *const @This()) bool { return false; }
/// };
/// comptime assertPagedPageCache(Cache);
/// ```
pub fn assertPagedPageCache(comptime PageCacheT: type) void {
    requiresErrorDeclaration(PageCacheT, "Error");
    requiresTypeDeclaration(PageCacheT, "Pid");
    requiresTypeDeclaration(PageCacheT, "Handle");
    const Error = PageCacheT.Error;
    const PageId = PageCacheT.Pid;
    const Handle = PageCacheT.Handle;
    requiresErrorDeclaration(Handle, "Error");
    requiresFnSignature(PageCacheT, "fetch", fn (*PageCacheT, PageId) Error!Handle);
    requiresFnSignature(PageCacheT, "create", fn (*PageCacheT) Error!Handle);
    requiresFnSignature(PageCacheT, "pageCount", fn (*const PageCacheT) usize);
    requiresFnSignature(PageCacheT, "pageSize", fn (*const PageCacheT) usize);
    requiresFnSignature(PageCacheT, "transactionActive", fn (*const PageCacheT) bool);
    requiresFnSignature(Handle, "deinit", fn (*Handle) void);
    requiresFnSignature(Handle, "pid", fn (*const Handle) Handle.Error!PageId);
    requiresFnSignature(Handle, "data", fn (*const Handle) Handle.Error![]const u8);
    requiresFnSignature(Handle, "dataMut", fn (*Handle) Handle.Error![]u8);
}

/// A paged GC storage manager owns the durable state root and sweep policy.
///
/// ```zig
/// const Manager = struct {
///     pub const PageId = u32;
///     pub const Error = error{};
///     pub fn getRoot(_: *const @This()) ?PageId { return null; }
///     pub fn setRoot(_: *@This(), _: ?PageId) Error!void {}
///     pub fn isReserved(_: *const @This(), _: PageId) bool { return false; }
///     pub fn isFree(_: *const @This(), _: PageId) Error!bool { return false; }
///     pub fn destroyPage(_: *@This(), _: PageId) Error!void {}
/// };
/// comptime assertPagedStorageManager(Manager, u32);
/// ```
pub fn assertPagedStorageManager(comptime StorageManagerT: type, comptime PageIdT: type) void {
    requiresErrorDeclaration(StorageManagerT, "Error");
    requiresTypeDeclaration(StorageManagerT, "PageId");
    if (StorageManagerT.PageId != PageIdT) {
        @compileError("GC storage manager PageId must match page cache Pid");
    }
    const Error = StorageManagerT.Error;
    requiresFnSignature(StorageManagerT, "getRoot", fn (*const StorageManagerT) ?PageIdT);
    requiresFnSignature(StorageManagerT, "setRoot", fn (*StorageManagerT, ?PageIdT) Error!void);
    requiresFnSignature(StorageManagerT, "isReserved", fn (*const StorageManagerT, PageIdT) bool);
    requiresFnSignature(StorageManagerT, "isFree", fn (*const StorageManagerT, PageIdT) Error!bool);
    requiresFnSignature(StorageManagerT, "destroyPage", fn (*StorageManagerT, PageIdT) Error!void);
}

/// Model contract for GC state, page access, and reclamation.
///
/// ```zig
/// const Model = struct {
///     pub const PageId = u32;
///     pub const Error = error{};
///     pub fn allocator(_: *const @This()) std.mem.Allocator { unreachable }
///     pub const Page = struct {};
///     pub fn isCycleActive(_: *const @This()) bool { return false; }
/// };
/// comptime assertRegistryModel(Model);
/// ```
pub fn assertModel(comptime ModelT: type) void {
    contract_interfaces.requiresTypeDeclaration(ModelT, "PageId");
    contract_interfaces.requiresErrorDeclaration(ModelT, "Error");
    const PageId = ModelT.PageId;
    const page_id_info = @typeInfo(PageId);
    if (page_id_info != .int or page_id_info.int.signedness != .unsigned) {
        @compileError("GC model PageId must be an unsigned integer type");
    }
    contract_interfaces.requiresFnSignature(
        ModelT,
        "allocator",
        fn (*const ModelT) std.mem.Allocator,
    );
    contract_interfaces.requiresFnSignature(
        ModelT,
        "isCycleActive",
        fn (*const ModelT) bool,
    );
}
