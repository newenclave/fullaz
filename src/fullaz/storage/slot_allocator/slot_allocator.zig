const std = @import("std");

pub const models = @import("models/models.zig");

pub fn SlotAllocator(comptime ModelT: type) type {
    return struct {
        pub const Model = ModelT;
    };
}
