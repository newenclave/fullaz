const std = @import("std");

fn isErrorUnion(comptime T: type) bool {
    return @typeInfo(T) == .error_union;
}

pub fn checkFnSignature(comptime T: type, comptime name: []const u8, comptime Expected: type) void {
    if (!@hasDecl(T, name)) {
        @compileError("Missing declaration: " ++ @typeName(T) ++ "." ++ name);
    }

    const Actual = @TypeOf(@field(T, name));
    if (Actual != Expected) {
        @compileError("Signature mismatch: " ++ @typeName(T) ++ "." ++ name ++ " expected: " ++ @typeName(Expected) ++ " got: " ++ @typeName(Actual));
    }
}

pub fn checkFnReturnsError(comptime T: type, comptime name: []const u8, comptime params: []const type, comptime result: type) void {
    if (!@hasDecl(T, name)) {
        @compileError("Missing declaration: " ++ @typeName(T) ++ "." ++ name);
    }

    const func = @field(T, name);
    const func_info = @typeInfo(@TypeOf(func)).@"fn";

    // Check parameter count (first param is self, so params.len + 1)
    if (func_info.params.len != params.len + 1) {
        @compileError(@typeName(T) ++ "." ++ name ++ " expected " ++ std.fmt.comptimePrint("{}", .{params.len + 1}) ++ " params, got " ++ std.fmt.comptimePrint("{}", .{func_info.params.len}));
    }

    // Check if return type is an error union
    if (!isErrorUnion(func_info.return_type.?)) {
        @compileError(@typeName(T) ++ "." ++ name ++ " must return an error union, got: " ++ @typeName(func_info.return_type.?));
    }

    // Check the payload type of the error union
    const return_info = @typeInfo(func_info.return_type.?);
    const payload_type = return_info.error_union.payload;
    if (payload_type != result) {
        @compileError(@typeName(T) ++ "." ++ name ++ " return type mismatch: expected result type " ++ @typeName(result) ++ ", got " ++ @typeName(payload_type));
    }
}

pub fn requireStorageManager(comptime T: type) void {
    if (!@hasDecl(T, "PageId")) {
        @compileError("StorageManager requires 'pub const PageId' type declaration");
    }
    checkFnSignature(T, "getRoot", fn (*const T) ?T.PageId);
    checkFnReturnsError(T, "setRoot", &.{?T.PageId}, void);
    //checkFnReturnsError(T, "hasRoot", &.{}, bool);
    checkFnSignature(T, "hasRoot", fn (*const T) bool);
    checkFnReturnsError(T, "destroyPage", &.{T.PageId}, void);
}
