const std = @import("std");

pub const models = @import("models/models.zig");

pub fn Fsm(comptime ModelT: type) type {
    return struct {
        const Self = @This();

        pub const Model = ModelT;
        pub const Pid = Model.Pid;
        pub const Error = ModelT.Error;
        pub const Size = ModelT.Size;
        pub const SlotInfo = ModelT.SlotInfo;

        model: *Model = undefined,

        pub fn init(model: *Model) Error!Self {
            return .{
                .model = model,
            };
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }
    };
}
