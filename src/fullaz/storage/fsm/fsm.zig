const std = @import("std");
const interfaces = @import("models/interfaces.zig");
pub const models = @import("models/models.zig");

pub fn Fsm2(comptime ModelT: type) type {
    comptime interfaces.assertModel(ModelT);

    return struct {
        const Self = @This();

        pub const Model = ModelT;
        pub const Pid = ModelT.Pid;
        pub const Size = ModelT.Size;
        pub const Error = ModelT.Error;

        model: *ModelT = undefined,

        pub fn init(model: *ModelT) Self {
            return .{ .model = model };
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn find(self: *Self, size: Size) Error!?Pid {
            return self.model.find(size);
        }

        pub fn add(self: *Self, pid: Pid, free: Size) Error!void {
            return self.model.add(pid, free);
        }

        pub fn update(self: *Self, pid: Pid, free: Size) Error!void {
            return self.model.update(pid, free);
        }

        pub fn remove(self: *Self, pid: Pid) Error!void {
            return self.model.remove(pid);
        }
    };
}
