const std = @import("std");
const core = @import("../core/core.zig");

pub const RebalancePolicy = enum {
    force_split,
    neighbor_share,
};

pub fn WeightedBpt(comptime ModelT: type) type {
    const Model = ModelT;
    const Accessor = Model.AccessorType;
    // const Weight = Model.WeightType;
    const ValueView = Model.ValueViewType;
    const Value = Model.ValueType;

    // const Leaf = Model.LeafType;
    // const Inode = Model.InodeType;
    const Error = Model.Error;

    return struct {
        const Self = @This();

        model: *Model,
        rebalance_policy: RebalancePolicy = .neighbor_share,

        pub fn init(model: *Model) Self {
            return .{
                .model = model,
            };
        }

        pub fn deinit(_: *Self) void {}

        pub fn insert(self: *Self, value: Value) Error!bool {
            const accessor = self.getAccessor();
            _ = accessor;
            const view = ValueView.init(value);
            defer view.deinit();
        }

        /// implementation fns. non public
        fn getAccessor(self: *Self) *Accessor {
            return self.model.getAccessor();
        }
    };
}
