const std = @import("std");

pub fn Memory(comptime KeyT: type, comptime ValueT: type, comptime cmp: anytype, comptime Ctx: type) type {
    const Context = struct {
        allocator: std.mem.Allocator,
        max_level: usize,
        rng: std.Random,
    };

    const PidImpl = struct {
        id: usize = undefined,
    };

    const NodeElement = struct {
        const Self = @This();
        const Error = error{OutOfMemory};

        const Links = struct {
            prev: ?PidImpl = undefined,
            next: ?PidImpl = undefined,
        };

        key: KeyT,
        value: ValueT,
        links: std.ArrayList(Links),
        ctx: *Context,

        fn init(ctx: *Context, key: KeyT, value: ValueT, level: usize) Error!Self {
            const links = try std.ArrayList(Links).initCapacity(ctx.allocator, level);
            var result = Self{
                .key = key,
                .value = value,
                .links = links,
                .ctx = ctx,
            };
            try result.links.resize(ctx.allocator, level);
            for (result.links.items) |*link| {
                link.* = .{
                    .prev = null,
                    .next = null,
                };
            }
            return result;
        }

        fn deinit(self: *Self) void {
            self.links.deinit(self.ctx.allocator);
            self.* = undefined;
        }
    };

    const NodeContainer = std.ArrayList(?NodeElement);
    const PidContainer = std.ArrayList(?PidImpl);

    const NodeImpl = struct {
        const Self = @This();

        pub const Error = error{ OutOfMemory, OutOfBounds };
        pub const KeyIn = KeyT;
        pub const ValueIn = ValueT;
        pub const KeyOut = *const KeyIn;
        pub const ValueOut = *const ValueIn;
        pub const Pid = PidImpl;

        element: *NodeElement = undefined,
        pid: PidImpl = undefined,

        fn init(node: *NodeElement, pid: usize) Error!Self {
            return Self{
                .element = node,
                .pid = PidImpl{ .id = pid },
            };
        }

        fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn getLevel(self: *const Self) Error!usize {
            return self.element.links.items.len;
        }

        pub fn getKey(self: *const Self) Error!KeyOut {
            return &self.element.key;
        }

        pub fn getValue(self: *const Self) Error!ValueOut {
            return &self.element.value;
        }

        pub fn setPrev(self: *Self, level: usize, pid: ?Pid) Error!void {
            if (level >= self.element.links.items.len) {
                return Error.OutOfMemory;
            }
            self.element.links.items[level].prev = pid;
        }

        pub fn setNext(self: *Self, level: usize, pid: ?Pid) Error!void {
            if (level >= self.element.links.items.len) {
                return Error.OutOfMemory;
            }
            self.element.links.items[level].next = pid;
        }

        pub fn getPrev(self: *const Self, level: usize) Error!?Pid {
            if (level >= self.element.links.items.len) {
                return Error.OutOfBounds;
            }
            return self.element.links.items[level].prev;
        }

        pub fn getNext(self: *const Self, level: usize) Error!?Pid {
            if (level >= self.element.links.items.len) {
                return Error.OutOfBounds;
            }
            return self.element.links.items[level].next;
        }

        pub fn id(self: *const Self) Pid {
            return self.pid;
        }
    };

    const PathImpl = struct {
        const Self = @This();
        pub const Error = error{ OutOfMemory, OutOfBounds };
        pub const Pid = PidImpl;

        path: PidContainer = undefined,

        fn init(allocator: std.mem.Allocator, max_level: usize) Error!Self {
            var result = Self{
                .path = try PidContainer.initCapacity(allocator, max_level),
            };
            try result.path.resize(
                allocator,
                max_level,
            );
            return result;
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.path.deinit(allocator);
            self.* = undefined;
        }

        pub fn get(self: *const Self, level: usize) Error!?PidImpl {
            if (self.path.items.len <= level) {
                return Error.OutOfBounds;
            }
            return self.path.items[level];
        }

        pub fn set(self: *Self, level: usize, pid: ?PidImpl) Error!void {
            if (self.path.items.len <= level) {
                return Error.OutOfBounds;
            }
            self.path.items[level] = pid;
        }

        fn dump(self: *const Self) void {
            for (self.path.items) |item| {
                if (item) |pid| {
                    std.debug.print("{d} ", .{pid.id});
                } else {
                    std.debug.print("<null> ", .{});
                }
            }
            std.debug.print("\n", .{});
        }
    };

    const AccessorImpl = struct {
        const Self = @This();

        pub const Path = PathImpl;
        pub const Node = NodeImpl;

        pub const KeyIn = KeyT;
        pub const ValueIn = ValueT;
        pub const Pid = PidImpl;

        pub const Error = error{ OutOfMemory, OutOfBounds };

        ctx: Context,
        cmp_ctx: Ctx = undefined,
        cont: NodeContainer = undefined,
        roots: PidContainer = undefined,

        fn init(allocator: std.mem.Allocator, max_level: usize, rng: std.Random) Error!Self {
            var result = Self{
                .ctx = .{
                    .allocator = allocator,
                    .max_level = max_level,
                    .rng = rng,
                },
                .cont = try NodeContainer.initCapacity(allocator, 8),
                .roots = try PidContainer.initCapacity(allocator, max_level),
            };
            errdefer result.cont.deinit(allocator);
            errdefer result.roots.deinit(allocator);

            try result.roots.resize(allocator, max_level);
            for (result.roots.items) |*item| {
                item.* = null;
            }
            return result;
        }

        fn deinit(self: *Self) void {
            for (self.cont.items) |*item| {
                if (item.*) |*node| {
                    node.deinit();
                }
            }
            self.cont.deinit(self.ctx.allocator);
            self.roots.deinit(self.ctx.allocator);
        }

        pub fn createNode(self: *Self, key: KeyT, value: ValueT) Error!NodeImpl {
            const level = try self.generateLevel(2) + 1;
            const id = self.cont.items.len;
            try self.cont.append(self.ctx.allocator, try NodeElement.init(&self.ctx, key, value, level));
            return NodeImpl.init(&self.cont.items[id].?, id);
        }

        pub fn loadNode(self: *const Self, pid: Pid) Error!NodeImpl {
            if (pid.id >= self.cont.items.len) {
                return Error.OutOfBounds;
            }
            if (self.cont.items[pid.id]) |*node| {
                return NodeImpl.init(node, pid.id);
            }
            return Error.OutOfBounds;
        }

        pub fn deinitNode(_: *const Self, node: *NodeImpl) void {
            node.deinit();
        }

        pub fn destroy(self: *Self, pid: PidImpl) void {
            const idx = pid.id;
            if (idx < self.cont.items.len) {
                if (self.cont.items[idx]) |*n| {
                    n.deinit();
                }
                self.cont.items[idx] = null;
            }
        }

        pub fn generateLevel(self: *const Self, k: usize) Error!usize {
            if (k == 0) {
                @panic("k must be greater than 0");
            }
            if (k == 1) {
                return self.ctx.rng.intRangeAtMost(usize, 1, self.ctx.max_level);
            }

            while (true) {
                var level: usize = 0;
                while (self.ctx.rng.intRangeAtMost(usize, 0, k - 1) == 0) {
                    level += 1;
                }

                if (level < self.ctx.max_level) {
                    return level;
                }
            }
        }

        pub fn getRoot(self: *const Self, level: usize) Error!?PidImpl {
            if (self.roots.items.len <= level) {
                return null;
            }
            return self.roots.items[level];
        }

        pub fn setRoot(self: *Self, level: usize, pid: ?PidImpl) Error!void {
            if (self.roots.items.len <= level) {
                return Error.OutOfMemory;
            }
            self.roots.items[level] = pid;
        }

        pub fn createPath(self: *Self) Error!PathImpl {
            return PathImpl.init(self.ctx.allocator, self.ctx.max_level);
        }

        pub fn deinitPath(self: *Self, path: *PathImpl) void {
            path.deinit(self.ctx.allocator);
        }
    };

    return struct {
        const Self = @This();

        pub const Error = error{ OutOfMemory, OutOfBounds };
        pub const Accessor = AccessorImpl;

        pub const Node = NodeImpl;
        pub const Pid = PidImpl;
        pub const KeyIn = KeyT;
        pub const ValueIn = ValueT;

        pub const KeyOut = *const KeyIn;
        pub const ValueOut = *const ValueIn;
        pub const Path = PathImpl;

        accessor: Accessor,

        pub fn init(allocator: std.mem.Allocator, max_level: usize, rng: std.Random) Error!Self {
            return .{
                .accessor = try Accessor.init(allocator, max_level, rng),
            };
        }

        pub fn deinit(self: *Self) void {
            self.accessor.deinit();
        }

        pub fn getMaxLevel(self: *const Self) Error!usize {
            return self.accessor.ctx.max_level;
        }

        pub fn getAccessor(self: *Self) *Accessor {
            return &self.accessor;
        }

        pub fn keysCompare(self: *const Self, k1: KeyIn, k2: KeyIn) std.math.Order {
            const CmpReturnType = @TypeOf(cmp(self.accessor.cmp_ctx, k1, k2));
            const is_error_union = @typeInfo(CmpReturnType) == .error_union;

            const order = blk: {
                if (comptime is_error_union) {
                    break :blk cmp(self.accessor.cmp_ctx, k1, k2) catch return .eq;
                } else {
                    break :blk cmp(self.accessor.cmp_ctx, k1, k2);
                }
            };
            return order;
        }

        pub fn keyOutAsIn(_: *const Self, key: KeyOut) KeyIn {
            return key.*;
        }

        pub fn valueOutAsIn(_: *const Self, value: ValueOut) ValueIn {
            return value.*;
        }
    };
}
