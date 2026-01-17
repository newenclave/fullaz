const std = @import("std");
fn checkFnSignature(comptime T: type, comptime name: []const u8, comptime Expected: type) bool {
    if (!@hasDecl(T, name)) {
        std.debug.print("Missing declaration: {s}\n", .{name});
        return false;
    }
    const Actual = @TypeOf(@field(T, name));
    if (Actual == Expected) {
        return true;
    }
    std.debug.print("Signature mismatch for {s}: expected {any}, got {any}\n", .{ name, Expected, Actual });
    return false;
}

/// Compile-time concept check for block device types.
/// A valid BlockDevice must have:
/// - `pub const BlockId` type
/// - `fn blockSize(*const Self) usize`
/// - `fn readBlock(*const Self, BlockId, []u8) !void`
/// - `fn writeBlock(*const Self, BlockId, []u8) !void`
/// - `fn appendBlock(*Self) !BlockId`
pub fn isBlockDevice(comptime T: type) bool {
    // Check for BlockId type
    if (!@hasDecl(T, "BlockId")) return false;
    if (@TypeOf(@field(T, "BlockId")) != type) return false; // Ensure it's a type, not a value

    // Check for blockSize function
    if (!@hasDecl(T, "blockSize")) return false;
    const blockSize_info = @typeInfo(@TypeOf(@field(T, "blockSize")));
    if (blockSize_info != .@"fn") return false;
    if (blockSize_info.@"fn".return_type != usize) return false;
    if (!checkFnSignature(T, "blockSize", fn (*const T) usize)) return false;

    // Check for readBlock function
    if (!@hasDecl(T, "readBlock")) return false;
    if (!checkFnSignature(T, "readBlock", fn (*const T, T.BlockId, []u8) anyerror!void)) return false;

    // Check for writeBlock function
    if (!@hasDecl(T, "writeBlock")) return false;
    if (!checkFnSignature(T, "writeBlock", fn (*const T, T.BlockId, []u8) anyerror!void)) return false;

    // Check for appendBlock function
    if (!@hasDecl(T, "appendBlock")) return false;
    if (!checkFnSignature(T, "appendBlock", fn (*const T) anyerror!T.BlockId)) return false;

    return true;
}

pub fn assertBlockDevice(comptime T: type) void {
    if (!@hasDecl(T, "BlockId")) {
        @compileError("BlockDevice requires 'pub const BlockId' type declaration");
    }

    if (@TypeOf(@field(T, "BlockId")) != type) {
        @compileError("BlockDevice 'BlockId' must be a type declaration");
    }

    if (!@hasDecl(T, "blockSize")) {
        @compileError("BlockDevice requires 'fn blockSize(*const Self) usize'");
    }
    if (!checkFnSignature(T, "blockSize", fn (*const T) usize)) {
        @compileError("BlockDevice 'blockSize' has incorrect signature; expected 'fn (*const Self) usize'");
    }

    if (!@hasDecl(T, "readBlock")) {
        @compileError("BlockDevice requires 'fn readBlock(*const Self, BlockId, []u8) !void'");
    }
    if (!checkFnSignature(T, "readBlock", fn (*const T, T.BlockId, []u8) anyerror!void)) {
        @compileError("BlockDevice 'readBlock' has incorrect signature; expected 'fn (*const Self, BlockId, []u8) !void'");
    }

    if (!@hasDecl(T, "writeBlock")) {
        @compileError("BlockDevice requires 'fn writeBlock(*const Self, BlockId, []u8) !void'");
    }
    if (!checkFnSignature(T, "writeBlock", fn (*const T, T.BlockId, []u8) anyerror!void)) {
        @compileError("BlockDevice 'writeBlock' has incorrect signature; expected 'fn (*const Self, BlockId, []u8) !void'");
    }

    if (!@hasDecl(T, "appendBlock")) {
        @compileError("BlockDevice requires 'fn appendBlock(*Self) !BlockId'");
    }
    if (!checkFnSignature(T, "appendBlock", fn (*T) anyerror!T.BlockId)) {
        @compileError("BlockDevice 'appendBlock' has incorrect signature; expected 'fn (*Self) !BlockId'");
    }
}
