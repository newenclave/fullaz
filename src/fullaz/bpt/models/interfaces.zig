const std = @import("std");

pub fn checkFnSignature(comptime T: type, comptime name: []const u8, comptime Expected: type) void {
    if (!@hasDecl(T, name)) {
        @compileError("Missing declaration: " ++ @typeName(T) ++ name);
    }

    const Actual = @TypeOf(@field(T, name));
    if (Actual != Expected) {
        @compileError("Signature mismatch: " ++ @typeName(T) ++ name ++ " expected: " ++ @typeName(Expected) ++ " got: " ++ @typeName(Actual));
    }
}

pub fn isStorageManager(comptime T: type) bool {
    if (!@hasDecl(T, "RootType")) {
        @compileError("RootType is missing");
    }

    // Check for getRoot function
    checkFnSignature(T, "getRoot", fn (self: *const T) ?T.RootType);

    // Check for setRoot function
    checkFnSignature(T, "setRoot", fn (self: *T, root: ?T.RootType) anyerror!void);

    // Check for hasRoot function
    checkFnSignature(T, "hasRoot", fn (self: *const T) bool);

    // Check for destroyPage function
    checkFnSignature(T, "destroyPage", fn (self: *T, id: T.RootType) anyerror!void);

    return true;
}

pub fn assertIsStorageManager(comptime T: type) void {
    if (!isStorageManager(T)) {
        @compileError(@typeName(T) ++ " is not a Storage Managerimplementation.");
    }
}
