const std = @import("std");
const errors = @import("../../core/errors.zig");

pub fn Model(comptime T: type, comptime MaximumElements: usize) type {
    const Pid = usize;
    const Weight = usize;

    //const Slice = []T;
    //const SliceConst = []const T;

    const Value = std.ArrayList(T);

    const InodeContainer = struct {
        const Self = @This();
        fn deinit(_: *Self, _: std.mem.Allocator) void {}
    };

    const LeafContainer = struct {
        const Self = @This();
        const Error = std.mem.Allocator.Error;

        values: std.ArrayList(Value),
        children: std.ArrayList(Pid),

        fn init(allocator: std.mem.Allocator) Error!Self {
            return .{
                .values = try std.ArrayList(Value).initCapacity(allocator, 0),
                .children = try std.ArrayList(Pid).initCapacity(allocator, 0),
            };
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (self.values.items) |*item| {
                item.deinit(allocator);
            }

            self.values.deinit(allocator);
            self.children.deinit(allocator);
        }
    };

    const InodeImpl = struct {
        const Self = @This();
        const Error = errors.HandleError || std.mem.Allocator.Error;

        pid: Pid,
        inode: ?*InodeContainer = null,

        fn init(inode: *InodeContainer, pid: Pid) Self {
            return .{
                .pid = pid,
                .inode = inode,
            };
        }

        pub fn id(self: *const Self) Pid {
            return self.pid;
        }

        fn check(self: *const Self) Error!void {
            if (self.inode == null) {
                return error.InvalidHandle;
            }
        }
    };

    const LeafImpl = struct {
        const Self = @This();
        const PidType = Pid;
        const Error = errors.HandleError || std.mem.Allocator.Error;

        pid: Pid,
        leaf: *LeafContainer = undefined,

        fn init(leaf: *LeafContainer, pid: Pid) Self {
            return .{
                .pid = pid,
                .leaf = leaf,
            };
        }

        pub fn size(self: *const Self) Error!usize {
            return self.leaf.values.items.len;
        }

        pub fn capacity(_: *const Self) Error!usize {
            return MaximumElements;
        }

        pub fn id(self: *const Self) Pid {
            return self.pid;
        }
    };

    const ValueViewImpl = struct {
        const Self = @This();
        value: *T,

        pub fn init(value: *T) Self {
            return .{
                .value = value,
            };
        }
        pub fn deinit(_: *Self) void {
            // no-op
        }
    };

    const NodeVariant = union(enum) {
        inode: InodeContainer,
        leaf: LeafContainer,
    };

    const AccessorImpl = struct {
        const Self = @This();

        const Error = errors.HandleError ||
            errors.IndexError ||
            std.mem.Allocator.Error;

        allocator: std.mem.Allocator,
        values: std.ArrayList(?NodeVariant),
        root: ?usize = null,

        fn init(allocator: std.mem.Allocator) Error!Self {
            return .{
                .allocator = allocator,
                .values = try std.ArrayList(?NodeVariant).initCapacity(allocator, 0),
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.values.items) |*item| {
                if (item.*) |*item_val| {
                    switch (item_val.*) {
                        .inode => |*inode| {
                            inode.deinit(self.allocator);
                        },
                        .leaf => |*leaf| {
                            leaf.deinit(self.allocator);
                        },
                    }
                }
            }
            self.values.deinit(self.allocator);
        }

        pub fn getRoot(self: *const Self) Error!?usize {
            return self.root;
        }

        pub fn setRoot(self: *Self, root: ?usize) Error!void {
            self.root = root;
        }

        pub fn createLeaf(self: *Self) Error!LeafImpl {
            const size = self.values.items.len;
            try self.values.append(self.allocator, .{
                .leaf = try LeafContainer.init(self.allocator),
            });
            return LeafImpl.init(&self.values.items[size].?.leaf, size);
        }

        pub fn loadLeaf(self: *Self, pid: Pid) Error!?LeafImpl {
            if (pid >= self.values.items.len) {
                return Error.OutOfBounds;
            }
            if (self.values.items[pid]) |*node| {
                return switch (node.*) {
                    .leaf => |*leaf| LeafImpl.init(leaf, pid),
                    else => return Error.OutOfBounds,
                };
            }
            return null;
        }

        pub fn deinitLeaf(_: *Self, _: LeafImpl) void {}

        pub fn createInode(self: *Self) Error!InodeImpl {
            const size = self.values.items.len;
            try self.values.append(self.allocator, .{
                .inode = InodeContainer{},
            });
            return InodeImpl.init(&self.values.items[size].?.inode, size);
        }

        pub fn loadInode(self: *Self, pid: Pid) Error!?InodeImpl {
            if (pid >= self.values.items.len) {
                return Error.OutOfBounds;
            }
            if (self.values.items[pid]) |*node| {
                return switch (node.*) {
                    .inode => |*inode| InodeImpl.init(inode, pid),
                    else => return Error.OutOfBounds,
                };
            }
            return null;
        }

        pub fn deinitInode(_: *Self, _: InodeImpl) void {}

        pub fn isLeaf(self: *const Self, pid: Pid) Error!bool {
            if (pid >= self.values.items.len) {
                return Error.OutOfBounds;
            }
            return switch (self.values.items[pid].?) {
                .leaf => true,
                .inode => false,
            };
        }
    };

    return struct {
        const Self = @This();
        pub const AccessorType = AccessorImpl;
        pub const ValueType = Value;
        pub const LeafType = LeafImpl;
        pub const InodeType = InodeImpl;
        pub const ValueViewType = ValueViewImpl;
        pub const WeightType = Weight;
        pub const PidType = Pid;

        pub const Error = error{} ||
            AccessorImpl.Error ||
            std.mem.Allocator.Error;

        accessor: AccessorImpl,

        pub fn init(allocator: std.mem.Allocator) Error!Self {
            return .{
                .accessor = try AccessorImpl.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.accessor.deinit();
        }

        pub fn getAccessor(self: *Self) *AccessorImpl {
            return &self.accessor;
        }
    };
}
