const std = @import("std");

pub fn isErrorUnion(comptime T: type) bool {
    return @typeInfo(T) == .error_union;
}

pub fn requiresErrorUnion(comptime T: type) void {
    if (!isErrorUnion(T)) {
        @compileError(@typeName(T) ++ " must be an error union type");
    }
}

pub fn isErrorType(comptime T: type) bool {
    const ti = @typeInfo(T);
    return ti == .error_set;
}

pub fn requiresTypeDeclaration(comptime T: type, comptime name: []const u8) void {
    if (!@hasDecl(T, name)) {
        @compileError("Missing type declaration: " ++ @typeName(T) ++ "." ++ name);
    }
}

pub fn requiresErrorType(comptime T: type) void {
    if (!isErrorType(T)) {
        @compileError(@typeName(T) ++ " must be an error set type");
    }
}

pub fn requiresErrorDeclaration(comptime T: type, comptime name: []const u8) void {
    requiresTypeDeclaration(T, name);
    requiresErrorType(@field(T, name));
}

pub fn requiresFnSignature(comptime T: type, comptime name: []const u8, comptime Expected: type) void {
    if (!@hasDecl(T, name)) {
        @compileError("Missing declaration: " ++ @typeName(T) ++ "." ++ name);
    }

    const Actual = @TypeOf(@field(T, name));
    if (Actual != Expected) {
        @compileError("Signature mismatch: " ++ @typeName(T) ++ "." ++ name ++
            " expected: " ++ @typeName(Expected) ++ " got: " ++ @typeName(Actual));
    }
}

pub fn requiresFnReturnsAnyError(comptime T: type, comptime name: []const u8, comptime params: []const type, comptime result: type) void {
    if (!@hasDecl(T, name)) {
        @compileError("Missing declaration: " ++ @typeName(T) ++ "." ++ name);
    }

    const func = @field(T, name);
    const func_info = @typeInfo(@TypeOf(func)).@"fn";

    // Check parameter count (first param is self, so params.len + 1)
    if (func_info.params.len != params.len + 1) {
        @compileError(@typeName(T) ++ "." ++ name ++
            " expected " ++ std.fmt.comptimePrint("{}", .{params.len + 1}) ++
            " params, got " ++ std.fmt.comptimePrint("{}", .{func_info.params.len}));
    }

    inline for (params, 0..) |ExpectedParamType, i| {
        const ActualParamType = func_info.params[i + 1].type.?;
        if (ActualParamType != ExpectedParamType) {
            @compileError(@typeName(T) ++ "." ++
                name ++ " param " ++
                std.fmt.comptimePrint("{}", .{i}) ++ " type mismatch: expected " ++
                @typeName(ExpectedParamType) ++ ", got " ++ @typeName(ActualParamType));
        }
    }

    // Check if return type is an error union
    if (!isErrorUnion(func_info.return_type.?)) {
        @compileError(@typeName(T) ++ "." ++ name ++
            " must return an error union, got: " ++ @typeName(func_info.return_type.?));
    }

    // Check the payload type of the error union
    const return_info = @typeInfo(func_info.return_type.?);
    const payload_type = return_info.error_union.payload;
    if (payload_type != result) {
        @compileError(@typeName(T) ++ "." ++ name ++
            " return type mismatch: expected result type " ++ @typeName(result) ++
            ", got " ++ @typeName(payload_type));
    }
}
