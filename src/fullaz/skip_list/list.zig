const std = @import("std");

pub fn List(comptime ModelT: type) type {
    return struct {
        const Self = @This();

        const Model = ModelT;
        const Accessor = ModelT.Accessor;

        pub const KeyIn = Model.KeyIn;
        pub const KeyOut = Model.KeyOut;
        pub const ValueIn = Model.ValueIn;
        pub const ValueOut = Model.ValueOut;

        pub const Pid = Model.Pid;
        const Path = Model.Path;

        pub const Error = Model.Error;

        model: *ModelT = undefined,
        pub fn init(model: *ModelT) Self {
            return .{
                .model = model,
            };
        }

        pub fn deinit(_: *Self) void {}

        pub fn getModel(self: *const Self) *ModelT {
            return self.model;
        }

        fn dump(self: *const Self) !void {
            const max_level = try self.model.getMaxLevel();
            for (0..max_level) |i| {
                std.debug.print("lvl {d}: ", .{i});
                if (try self.getAccessor().getRoot(i)) |root_pid| {
                    var curr_pid: ?Pid = root_pid;
                    while (curr_pid) |pid| {
                        const node = try self.getAccessor().loadNode(pid);
                        std.debug.print("{d} ", .{try node.getKey()});
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
                const cmp_res = self.model.keysCompare(key, try node.getKey());
                if (cmp_res == .eq) {
                    target = pid;
                }
            }

            if (target) |pid| {
                var node = try acc.loadNode(pid);
                defer acc.deinitNode(&node);
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
                acc.destroyNode(&node);
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

        fn findElement(self: *Self, from: ?Pid, key: KeyIn, level: usize) Error!?Pid {
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

                const cmp_res = self.model.keysCompare(key, try node.getKey());
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
