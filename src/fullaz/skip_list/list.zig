const std = @import("std");
const errors = @import("../core/errors.zig");

pub fn List(comptime ModelT: type) type {
    return struct {
        const Self = @This();

        const Model = ModelT;
        const Accessor = ModelT.Accessor;

        pub const KeyIn = Model.KeyIn;
        pub const KeyOut = Model.KeyOut;
        pub const ValueIn = Model.ValueIn;
        pub const ValueOut = Model.ValueOut;

        const Node = Model.Node;

        pub const Pid = Model.Pid;
        const Path = Model.Path;

        pub const Error = Model.Error || errors.IteratorError;

        model: *ModelT = undefined,

        pub const Iterator = struct {
            const Cursor = union(enum) {
                before_first,
                on: Node,
                after_last,
            };

            list: *const Self,
            cursor: Cursor,

            fn init(list: *const Self, cursor: Cursor) Iterator {
                return .{
                    .list = list,
                    .cursor = cursor,
                };
            }

            pub fn deinit(self: *Iterator) void {
                var acc = self.list.getAccessor();
                switch (self.cursor) {
                    .before_first, .after_last => {},
                    .on => |*node| {
                        acc.deinitNode(node);
                    },
                }
            }

            pub fn key(self: *const Iterator) Error!KeyOut {
                return switch (self.cursor) {
                    .before_first, .after_last => return Error.InvalidIterator,
                    .on => |*node| try node.getKey(),
                };
            }

            pub fn value(self: *const Iterator) Error!ValueOut {
                return switch (self.cursor) {
                    .before_first, .after_last => return Error.InvalidIterator,
                    .on => |*node| try node.getValue(),
                };
            }

            pub fn next(self: *Iterator) Error!bool {
                var acc = self.list.getAccessor();
                switch (self.cursor) {
                    .before_first => {
                        if (try acc.getRoot(0)) |root_pid| {
                            const node = try acc.loadNode(root_pid);
                            self.cursor = .{ .on = node };
                            return true;
                        } else {
                            self.cursor = .after_last;
                            return false;
                        }
                    },
                    .on => |*node| {
                        if (try node.getNext(0)) |next_pid| {
                            const next_node = try acc.loadNode(next_pid);
                            errdefer acc.deinitNode(&next_node);
                            acc.deinitNode(node);
                            self.cursor = .{ .on = next_node };
                            return true;
                        } else {
                            acc.deinitNode(node);
                            self.cursor = .after_last;
                            return false;
                        }
                    },
                    .after_last => return false,
                }
            }

            pub fn isEnd(self: *const Iterator) bool {
                return switch (self.cursor) {
                    .before_first => false,
                    .on => false,
                    .after_last => true,
                };
            }
        };

        pub fn init(model: *ModelT) Self {
            return .{
                .model = model,
            };
        }

        pub fn deinit(_: *Self) void {}

        pub fn begin(self: *const Self) Error!Iterator {
            var acc = self.getAccessor();
            if (try acc.getRoot(0)) |root_pid| {
                const node = try acc.loadNode(root_pid);
                return Iterator.init(self, .{ .on = node });
            } else {
                return Iterator.init(self, .before_first);
            }
        }

        pub fn getModel(self: *const Self) *ModelT {
            return self.model;
        }

        pub fn dump(
            self: *const Self,
            comptime keyDumper: ?fn (KeyOut) void,
            comptime valueDumper: ?fn (ValueOut) void,
        ) !void {
            const max_level = try self.model.getMaxLevel();
            for (0..max_level) |i| {
                std.debug.print("lvl {d}: ", .{i});
                if (try self.getAccessor().getRoot(i)) |root_pid| {
                    var curr_pid: ?Pid = root_pid;
                    while (curr_pid) |pid| {
                        const node = try self.getAccessor().loadNode(pid);
                        if (keyDumper) |kf| {
                            kf(try node.getKey());
                        } else {
                            std.debug.print("{any}:", .{try node.getKey()});
                        }
                        if (valueDumper) |vf| {
                            vf(try node.getValue());
                        } else {
                            std.debug.print("({any}) ", .{try node.getValue()});
                        }
                        curr_pid = try node.getNext(i);
                    }
                } else {
                    std.debug.print("<null>", .{});
                }
                std.debug.print("\n", .{});
            }
        }

        pub fn insert(self: *Self, key: KeyIn, value: ValueIn) Error!void {
            const acc = self.getAccessor();
            var new_node = try acc.createNode(key, value);

            defer acc.deinitNode(&new_node);

            var path = try self.createPath(key);
            defer acc.deinitPath(&path);

            const level = try new_node.getLevel();
            for (0..level) |i| {
                if (try path.get(i)) |pid| {
                    var node = try acc.loadNode(pid);
                    const fwd = try node.getNext(i);
                    try node.setNext(i, new_node.id());
                    try new_node.setNext(i, fwd);
                    try new_node.setPrev(i, pid);
                    if (fwd) |fwd_pid| {
                        var fwd_node = try acc.loadNode(fwd_pid);
                        try fwd_node.setPrev(i, new_node.id());
                    }
                } else {
                    if (try acc.getRoot(i)) |root_pid| {
                        var root_node = try acc.loadNode(root_pid);
                        try new_node.setNext(i, root_pid);
                        try root_node.setPrev(i, new_node.id());
                    }
                    try acc.setRoot(i, new_node.id());
                }
            }
        }

        pub fn remove(self: *Self, key: KeyIn) Error!void {
            const acc = self.getAccessor();
            var path = try self.createPath(key);
            defer acc.deinitPath(&path);

            var target: ?Pid = null;
            if (try path.get(0)) |pid| {
                var node = try acc.loadNode(pid);
                defer acc.deinitNode(&node);
                const nodeKey = try node.getKey();
                const cmp_res = self.model.keysCompare(key, self.model.keyOutAsIn(nodeKey));
                if (cmp_res == .eq) {
                    target = pid;
                }
            }

            if (target) |pid| {
                var node = try acc.loadNode(pid);
                defer {
                    const id = node.id();
                    acc.deinitNode(&node);
                    acc.destroy(id);
                }
                try self.removeImpl(&node);
            }
        }

        pub fn removeItr(self: *Self, it: Iterator) Error!Iterator {
            var acc = self.getAccessor();

            var next = it;
            errdefer next.deinit();
            _ = next.next() catch return Iterator.init(self, .after_last);

            switch (it.cursor) {
                .before_first, .after_last => return Error.InvalidIterator,
                .on => |node| {
                    var mutNode = node;
                    defer {
                        const pid = node.id();
                        acc.deinitNode(&mutNode);
                        acc.destroy(pid);
                    }
                    try self.removeImpl(&mutNode);
                    return next;
                },
            }
        }

        fn removeImpl(self: *Self, node: *Node) Error!void {
            const acc = self.getAccessor();

            const level = try node.getLevel();
            for (0..level) |i| {
                if (try node.getPrev(i)) |prev_pid| {
                    var prev_node = try acc.loadNode(prev_pid);
                    defer acc.deinitNode(&prev_node);
                    const next_pid = try node.getNext(i);
                    try prev_node.setNext(i, next_pid);
                    if (next_pid) |nxt_pid| {
                        var nxt_node = try acc.loadNode(nxt_pid);
                        defer acc.deinitNode(&nxt_node);
                        try nxt_node.setPrev(i, prev_pid);
                    }
                } else {
                    const next_pid = try node.getNext(i);
                    try acc.setRoot(i, next_pid);
                    if (next_pid) |nxt_pid| {
                        var nxt_node = try acc.loadNode(nxt_pid);
                        defer acc.deinitNode(&nxt_node);
                        try nxt_node.setPrev(i, null);
                    }
                }
            }
        }

        pub fn find(self: *const Self, key: KeyIn) Error!Iterator {
            const default_iterator = Iterator.init(self, .after_last);
            const pid = try self.findElement(null, key, 0) orelse return default_iterator;
            var node = try self.getAccessor().loadNode(pid);
            defer self.getAccessor().deinitNode(&node);
            if (self.model.keysCompare(key, self.model.keyOutAsIn(try node.getKey())) == .eq) {
                return Iterator.init(self, .{ .on = node });
            } else {
                return default_iterator;
            }
        }

        pub fn contains(self: *Self, key: KeyIn) Error!bool {
            const pid = try self.findElement(null, key, 0) orelse return false;
            var node = try self.getAccessor().loadNode(pid);
            defer self.getAccessor().deinitNode(&node);
            return self.model.keysCompare(key, try node.getKey()) == .eq;
        }

        fn createPath(self: *Self, key: KeyIn) Error!Path {
            var path = try self.getAccessor().createPath();
            errdefer self.getAccessor().deinitPath(&path);
            const max_level = try self.model.getMaxLevel();
            var link: ?Pid = null;
            for (0..max_level) |i| {
                const level = max_level - 1 - i;
                link = try self.findElement(link, key, level);
                try path.set(level, link);
            }
            return path;
        }

        fn findElement(self: *const Self, from: ?Pid, key: KeyIn, level: usize) Error!?Pid {
            const acc = self.getAccessor();
            var prev: ?Pid = from;
            var curr: ?Pid = null;
            if (from) |pid| {
                var node = try acc.loadNode(pid);
                defer acc.deinitNode(&node);
                curr = try node.getNext(level);
            } else {
                curr = try acc.getRoot(level);
            }

            while (curr) |pid| {
                var node = try acc.loadNode(pid);
                defer acc.deinitNode(&node);

                const nodeKey = try node.getKey();

                const cmp_res = self.model.keysCompare(key, self.model.keyOutAsIn(nodeKey));
                if (cmp_res == .lt) {
                    return prev;
                }
                prev = pid;
                curr = try node.getNext(level);
            }
            return prev;
        }

        fn getAccessor(self: *const Self) *Accessor {
            return self.model.getAccessor();
        }
    };
}
