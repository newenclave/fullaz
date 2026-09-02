const std = @import("std");

/// Interprets one state lease as a checked byte-aligned durable state struct.
pub fn StateAccessor(comptime StateLeaseT: type, comptime StateT: type) type {
    if (@typeInfo(StateT) != .@"struct" or @typeInfo(StateT).@"struct".layout != .@"extern") {
        @compileError("Storage state must be an extern struct");
    }
    if (@alignOf(StateT) != 1 or @sizeOf(StateT) == 0) {
        @compileError("Storage state must be non-empty and byte-aligned");
    }

    return struct {
        pub const Error = StateLeaseT.Error || error{BadData};

        pub fn view(lease: *const StateLeaseT) Error!*const StateT {
            const bytes = try lease.data();
            if (bytes.len != @sizeOf(StateT)) {
                return error.BadData;
            }
            return @ptrCast(bytes.ptr);
        }

        pub fn viewMut(lease: *StateLeaseT) Error!*StateT {
            const bytes = try lease.dataMut();
            if (bytes.len != @sizeOf(StateT)) {
                return error.BadData;
            }
            return @ptrCast(bytes.ptr);
        }
    };
}
