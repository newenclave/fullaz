const std = @import("std");
const errors = @import("../../core/errors.zig");
const interfaces = @import("models/interfaces.zig");

pub fn TreeImpl(comptime ModelT: type) type {
    comptime {
        interfaces.assertModel(ModelT);
    }

    const ErrorSet = error{};

    return struct {
        const Self = @This();
        pub const Error = ErrorSet;
        pub const Model = ModelT;
        pub const Accessor = Model.Accessor;
        pub const NodeId = Model.NodeId;
        pub const Node = Model.Node;
        pub const Box = Model.Box;

        model: *Model,

        pub fn init(model: *Model) Self {
            return Self{
                .model = model,
            };
        }

        fn getAccessor(self: *const Self) *Accessor {
            return &self.model.getAccessor();
        }
    };
}
