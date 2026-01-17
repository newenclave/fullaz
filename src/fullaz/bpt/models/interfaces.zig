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

pub fn isStorageManager(comptime T: type) bool {
    // Check for getRoot function
    if (!checkFnSignature(T, "getRoot", fn (self: *@This()) ?u64)) return false;

    // Check for setRoot function
    if (!checkFnSignature(T, "setRoot", fn (self: *@This(), root: ?u64) !void)) return false;

    // Check for hasRoot function
    if (!checkFnSignature(T, "hasRoot", fn (self: *@This()) bool)) return false;

    // Check for destroyPage function
    if (!checkFnSignature(T, "destroyPage", fn (self: *@This(), id: u64) !void)) return false;

    return true;
}
