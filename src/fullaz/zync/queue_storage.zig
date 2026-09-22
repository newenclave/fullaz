const std = @import("std");

/// Queue storage strategies for one task type.
pub fn Storage(comptime T: type) type {
    return struct {
        pub const Task = T;

        /// Allocator-backed FIFO storage based on `std.Deque`.
        pub const Deque = struct {
            const Self = @This();

            pub const Task = T;
            pub const Error = std.mem.Allocator.Error;

            pub const Policy = struct {
                allocator: std.mem.Allocator,

                pub fn init(allocator: std.mem.Allocator) Policy {
                    return .{ .allocator = allocator };
                }
            };

            items: std.Deque(T) = .empty,
            allocator: std.mem.Allocator,

            pub fn init(policy: Policy) Self {
                return .{ .allocator = policy.allocator };
            }

            pub fn deinit(self: *Self) void {
                self.items.deinit(self.allocator);
                self.* = undefined;
            }

            pub fn push(self: *Self, value: T) Error!void {
                try self.items.pushBack(self.allocator, value);
            }

            pub fn pop(self: *Self) ?T {
                return self.items.popFront();
            }

            pub fn isEmpty(self: *const Self) bool {
                return self.items.len == 0;
            }

            pub fn peek(self: *const Self) ?T {
                return self.items.front();
            }
        };

        /// Allocation-free FIFO storage embedded directly in its owner.
        pub fn Fixed(comptime maximum_items: usize) type {
            comptime {
                if (maximum_items == 0) {
                    @compileError("zync.Storage.Fixed requires at least one item");
                }
            }

            return struct {
                const Self = @This();

                pub const Task = T;
                pub const Error = error{NotEnoughSpace};
                pub const Policy = struct {};

                items: [maximum_items]T = undefined,
                head: usize = 0,
                len: usize = 0,

                pub fn init(_: Policy) Self {
                    return .{};
                }

                pub fn deinit(self: *Self) void {
                    self.* = undefined;
                }

                pub fn push(self: *Self, value: T) Error!void {
                    if (self.len == maximum_items) {
                        return error.NotEnoughSpace;
                    }

                    const until_end = maximum_items - self.head;
                    const tail = if (self.len >= until_end)
                        self.len - until_end
                    else
                        self.head + self.len;
                    self.items[tail] = value;
                    self.len += 1;
                }

                pub fn pop(self: *Self) ?T {
                    if (self.len == 0) {
                        return null;
                    }

                    const value = self.items[self.head];
                    self.head += 1;
                    if (self.head == maximum_items) {
                        self.head = 0;
                    }
                    self.len -= 1;
                    return value;
                }

                pub fn isEmpty(self: *const Self) bool {
                    return self.len == 0;
                }

                pub fn peek(self: *const Self) ?T {
                    if (self.len == 0) {
                        return null;
                    }
                    return self.items[self.head];
                }
            };
        }

        /// Allocator-backed storage that pops values in comparator order.
        pub fn Priority(
            comptime ContextT: type,
            comptime compareFn: anytype,
        ) type {
            const CompareFn = fn (context: ContextT, a: T, b: T) std.math.Order;
            comptime {
                if (@TypeOf(compareFn) != CompareFn) {
                    @compileError("zync.Storage.Priority comparator must have signature " ++
                        @typeName(CompareFn));
                }
            }

            const Queue = std.PriorityQueue(T, ContextT, compareFn);
            return struct {
                const Self = @This();

                pub const Task = T;
                pub const Error = std.mem.Allocator.Error;

                pub const Policy = struct {
                    allocator: std.mem.Allocator,
                    context: ContextT,

                    pub fn init(
                        allocator: std.mem.Allocator,
                        context: ContextT,
                    ) Policy {
                        return .{
                            .allocator = allocator,
                            .context = context,
                        };
                    }
                };

                items: Queue,
                allocator: std.mem.Allocator,

                pub fn init(policy: Policy) Self {
                    return .{
                        .items = .initContext(policy.context),
                        .allocator = policy.allocator,
                    };
                }

                pub fn deinit(self: *Self) void {
                    self.items.deinit(self.allocator);
                    self.* = undefined;
                }

                pub fn push(self: *Self, value: T) Error!void {
                    try self.items.push(self.allocator, value);
                }

                pub fn pop(self: *Self) ?T {
                    return self.items.pop();
                }

                pub fn isEmpty(self: *const Self) bool {
                    return self.items.count() == 0;
                }

                pub fn peek(self: *const Self) ?T {
                    return self.items.peek();
                }
            };
        }
    };
}
