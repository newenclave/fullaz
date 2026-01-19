const interfaces = @import("../interfaces.zig");

const isErrorType = interfaces.isErrorType;
const isErrorUnion = interfaces.isErrorUnion;
const requiresFnSignature = interfaces.requiresFnSignature;
const requiresFnReturnsAnyError = interfaces.requiresFnReturnsAnyError;
const requiresTypeDeclaration = interfaces.requiresTypeDeclaration;
const requiresErrorDeclaration = interfaces.requiresErrorDeclaration;

/// Compile-time concept check for block device types.
/// A valid BlockDevice must have:
/// - `pub const Error` error set
/// - `pub const BlockId` type
/// - `fn blockSize(*const Self) usize`
/// - `fn readBlock(*const Self, BlockId, []u8) !void`
/// - `fn writeBlock(*const Self, BlockId, []u8) !void`
/// - `fn appendBlock(*Self) !BlockId`
/// - `fn blocksCount(*const Self) usize`
pub fn assertBlockDevice(comptime T: type) void {
    requiresTypeDeclaration(T, "BlockId");
    requiresErrorDeclaration(T, "Error");

    requiresFnSignature(T, "isValidId", fn (*const T, T.BlockId) bool);
    requiresFnSignature(T, "isOpen", fn (*const T) bool);
    requiresFnSignature(T, "blockSize", fn (*const T) usize);
    requiresFnSignature(T, "blocksCount", fn (*const T) usize);
    requiresFnReturnsAnyError(T, "readBlock", &.{ T.BlockId, []u8 }, void);
    requiresFnReturnsAnyError(T, "writeBlock", &.{ T.BlockId, []u8 }, void);
    requiresFnReturnsAnyError(T, "appendBlock", &.{}, T.BlockId);
}
