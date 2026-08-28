const interfaces = @import("interfaces.zig");

const requiresErrorDeclaration = interfaces.requiresErrorDeclaration;
const requiresFnSignature = interfaces.requiresFnSignature;
const requiresTypeDeclaration = interfaces.requiresTypeDeclaration;

/// A virtual page map owns a dense, one-to-one virtual-to-physical page-ID mapping.
///
/// ```zig
/// const Map = struct {
///     pub const PhysicalPageIdType = u32;
///     pub const VirtualPageIdType = u32;
///     pub const Error = error{};
///     pub const WriteBatch = struct {
///         pub fn commit(_: *@This()) void {}
///         pub fn discard(_: *@This()) void {}
///     };
///     pub const append_only_dense_virtual_page_ids = true;
///
///     pub fn prepareSet(_: *Map) Error!void {}
///     pub fn set(_: *Map, _: PhysicalPageIdType) Error!VirtualPageIdType { return 0; }
///     pub fn get(_: *const Map, _: VirtualPageIdType) Error!PhysicalPageIdType { return 0; }
///     pub fn remap(_: *Map, _: VirtualPageIdType, _: PhysicalPageIdType) Error!void {}
///     pub fn pageCount(_: *const Map) usize { return 0; }
///     pub fn begin(_: *Map) Error!WriteBatch { return .{}; }
///     pub fn transactionActive(_: *const Map) bool { return false; }
/// };
/// comptime assertVirtualPageMap(Map);
/// ```
pub fn assertVirtualPageMap(comptime T: type) void {
    requiresErrorDeclaration(T, "Error");
    requiresTypeDeclaration(T, "PhysicalPageIdType");
    requiresTypeDeclaration(T, "VirtualPageIdType");
    requiresTypeDeclaration(T, "WriteBatch");

    const Error = T.Error;
    const PhysicalPageIdType = T.PhysicalPageIdType;
    const VirtualPageIdType = T.VirtualPageIdType;
    const WriteBatch = T.WriteBatch;

    assertUnsignedInteger(PhysicalPageIdType, "PhysicalPageIdType");
    assertUnsignedInteger(VirtualPageIdType, "VirtualPageIdType");

    if (!@hasDecl(T, "append_only_dense_virtual_page_ids") or
        @TypeOf(T.append_only_dense_virtual_page_ids) != bool or
        !T.append_only_dense_virtual_page_ids)
    {
        @compileError("VirtualPageMap must guarantee append-only dense virtual page IDs");
    }

    requiresFnSignature(T, "prepareSet", fn (*T) Error!void);
    requiresFnSignature(T, "set", fn (*T, PhysicalPageIdType) Error!VirtualPageIdType);
    requiresFnSignature(T, "get", fn (*const T, VirtualPageIdType) Error!PhysicalPageIdType);
    requiresFnSignature(T, "remap", fn (*T, VirtualPageIdType, PhysicalPageIdType) Error!void);
    requiresFnSignature(T, "pageCount", fn (*const T) usize);
    requiresFnSignature(T, "begin", fn (*T) Error!WriteBatch);
    requiresFnSignature(T, "transactionActive", fn (*const T) bool);
    requiresFnSignature(WriteBatch, "commit", fn (*WriteBatch) void);
    requiresFnSignature(WriteBatch, "discard", fn (*WriteBatch) void);
}

fn assertUnsignedInteger(comptime T: type, comptime name: []const u8) void {
    switch (@typeInfo(T)) {
        .int => |integer| {
            if (integer.signedness != .unsigned) {
                @compileError("VirtualPageMap." ++ name ++ " must be unsigned");
            }
        },
        else => @compileError("VirtualPageMap." ++ name ++ " must be an integer"),
    }
}
