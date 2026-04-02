const std = @import("std");
const KeySplitter = @import("splitter.zig").Splitter;
const errors = @import("../core/errors.zig");

pub fn Tree(comptime ModelT: type) type {
    const Model = ModelT;
    const Leaf = Model.Leaf;

    const KeyInType = Model.KeyIn;
    const ValueInType = Model.ValueIn;
    const ValueOutType = Model.ValueOut;
    const Pid = Model.Pid;

    const SplitKeyResult = Model.SplitKeyResult;

    return struct {
        const Self = @This();

        const Splitter = KeySplitter(KeyInType);
        const Error = Splitter.Error ||
            Model.Error || errors.LayoutError;

        model: *Model,
        splitter: Splitter,

        pub fn init(model: *Model) Self {
            return Self{
                .model = model,
                .splitter = Splitter.init(
                    model.getSettings().inode_base,
                    model.getSettings().leaf_base,
                ),
            };
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        fn debugPrintSplitKey(key: KeyInType, skr: *const SplitKeyResult) void {
            if (@import("builtin").mode == .Debug) {
                std.debug.print("Key 0x{X:0>8} -> {} levels:\n", .{ key, skr.size() });
                for (skr.items, 0..) |kd, i| {
                    const level_type = if (kd.level == 0) "LEAF" else "INODE";
                    std.debug.print("  [{}] {s} digit={:3} quot={:8}\n", .{
                        i,
                        level_type,
                        kd.digit,
                        kd.quotient,
                    });
                }
            }
        }

        pub fn dumpTree(self: *Self, writer: anytype) Error!void {
            const acc = self.getAccessor();

            if (try acc.getRoot()) |root_id| {
                const root_level = (try acc.getRootLevel()) orelse 0;
                try writer.print("=== Radix Tree Dump ===\n", .{});
                try writer.print("Root PID: {}, Level: {}\n\n", .{ root_id, root_level });
                try self.dumpNode(writer, root_id, 0, 0); // indent=0, path=0
            } else {
                try writer.print("Tree is empty\n", .{});
            }
        }

        fn dumpNode(self: *Self, writer: anytype, pid: usize, indent: usize, path: u64) Error!void {
            const acc = self.getAccessor();

            // Print indentation
            for (0..indent) |_| {
                try writer.print("  ", .{});
            }

            if (try acc.isLeaf(@intCast(pid))) {
                var leaf = try acc.loadLeaf(@intCast(pid));
                defer acc.deinitLeaf(&leaf);

                try writer.print("LEAF[{}] (parent={?}[{any}], parent_quot={}) {} values:\n", .{
                    pid,
                    try leaf.getParent(),
                    try leaf.getParentId(),
                    try leaf.getParentQuotient(),
                    try leaf.size(),
                });

                // TODO: avaid to use inode.container here.
                // Only print non-null values
                for (0..try leaf.capacity()) |i| {
                    if (try leaf.isSet(@intCast(i))) {
                        for (0..indent + 1) |_| try writer.print("  ", .{});
                        try writer.print("[{}] = {any}\n", .{ i, try leaf.get(@intCast(i)) });
                    }
                }
            } else {
                var inode = try acc.loadInode(@intCast(pid));
                defer acc.deinitInode(&inode);

                const level = try inode.getLevel();
                try writer.print("INODE[{}] Level={} (parent={?}[{any}]) {} children:\n", .{
                    pid,
                    level,
                    try inode.getParent(),
                    try inode.getParentId(),
                    try inode.size(),
                });

                // TODO: avaid to use inode.container here.
                // Recursively dump children (only non-null)

                for (0..try inode.capacity()) |i| {
                    if (try inode.isSet(@intCast(i))) {
                        for (0..indent + 1) |_| {
                            try writer.print("  ", .{});
                        }
                        const child_pid = try inode.get(@intCast(i));
                        try writer.print("[{}] -> PID {}, Parent {any}[{any}], parent_quot {any} \n", .{
                            i,
                            child_pid,
                            try inode.getParent(),
                            try inode.getParentId(),
                            try inode.getParentQuotient(),
                        });

                        // Recurse into child
                        try self.dumpNode(writer, child_pid, indent + 2, (path * 512) + i);
                    }
                }
            }
        }

        pub fn get(self: *Self, key: KeyInType) !?ValueOutType {
            const acc = self.getAccessor();
            var split_key = try acc.splitKey(key);
            defer acc.deinitSplitKey(&split_key);
            var leaf_value = try self.findLeaf(&split_key);
            if (leaf_value) |*leaf| {
                defer acc.deinitLeaf(leaf);
                const digit = split_key.get(0).digit;
                if (try leaf.isSet(digit)) {
                    return try leaf.get(digit);
                }
            }
            return null;
        }

        pub fn set(self: *Self, key: KeyInType, value: ValueInType) Error!void {
            const acc = self.getAccessor();
            var split_key = try acc.splitKey(key);
            defer acc.deinitSplitKey(&split_key);
            //debugPrintSplitKey(key, &split_key);
            try self.growUpPath(split_key.size() - 1);
            var leaf = try self.createPath(&split_key);
            defer acc.deinitLeaf(&leaf);
            try leaf.set(split_key.get(0).digit, value);
        }

        pub fn free(self: *Self, key: KeyInType) Error!void {
            const acc = self.getAccessor();
            var split_key = try acc.splitKey(key);
            defer acc.deinitSplitKey(&split_key);
            var leaf_value = try self.findLeaf(&split_key);
            if (leaf_value) |*leaf| {
                defer acc.deinitLeaf(leaf);
                const digit = split_key.get(0).digit;
                if (try leaf.isSet(digit)) {
                    try leaf.free(digit);
                    if (try leaf.size() == 0) {
                        const parent = try leaf.getParent();
                        const parent_id = try leaf.getParentId();
                        try acc.destroy(leaf.id());
                        try self.freeChild(parent, parent_id);
                    }
                }
            }
        }

        fn freeChild(self: *Self, inode_id: ?Pid, id: KeyInType) Error!void {
            const acc = self.getAccessor();
            if (inode_id) |pid| {
                var inode = try acc.loadInode(pid);
                defer acc.deinitInode(&inode);
                if (try inode.isSet(id)) {
                    try inode.free(id);
                    if (try inode.size() == 0) {
                        const parent = try inode.getParent();
                        const parent_id = try inode.getParentId();
                        try acc.destroy(pid);
                        try self.freeChild(parent, parent_id);
                    }
                }
            }
        }

        fn findLeaf(self: *Self, skr: *const SplitKeyResult) Error!?Leaf {
            const acc = self.getAccessor();
            const key_level = skr.size() - 1;

            if (try acc.getRoot()) |root_id| {
                var current_lvl = (try acc.getRootLevel()) orelse 0;
                var current_id = root_id;
                if (current_lvl < key_level) {
                    return null;
                }
                while (true) {
                    if (try acc.isLeaf(current_id)) {
                        return try acc.loadLeaf(current_id);
                    } else {
                        if (current_lvl == 0) {
                            return Error.InconsistentLayout;
                        }
                        var inode = try acc.loadInode(current_id);
                        defer acc.deinitInode(&inode);
                        const digit = skr.get(current_lvl).digit;
                        if (!try inode.isSet(digit)) {
                            return null;
                        }
                        current_id = try inode.get(digit);
                        current_lvl -= 1;
                    }
                }
            }
            return null;
        }

        fn createPath(self: *Self, skr: *const SplitKeyResult) Error!Leaf {
            const acc = self.getAccessor();
            if (try acc.getRootLevel()) |root_level| {
                if (root_level < (skr.size() - 1)) {
                    return Error.InvalidId;
                }

                if (try acc.getRoot()) |root_id| {
                    var current_id = root_id;
                    var current_lvl = root_level;
                    while (current_lvl >= 0) {
                        if (current_lvl == 0) {
                            if (try acc.isLeaf(current_id)) {
                                return try acc.loadLeaf(current_id);
                            } else {
                                // Tree corruption: inode at level 0!
                                std.debug.print("ERROR: Tree corruption detected!\n", .{});
                                std.debug.print("  Expected: Leaf at level 0\n", .{});
                                std.debug.print("  Got: Inode at PID {}\n", .{current_id});
                                return Error.InconsistentLayout;
                            }
                        } else {
                            var inode = try acc.loadInode(current_id);
                            defer acc.deinitInode(&inode);
                            const next_lvl = current_lvl - 1;
                            const current_digit = skr.get(current_lvl).digit;
                            const next_level_quot = skr.get(next_lvl).quotient;
                            if (try inode.isSet(current_digit)) {
                                current_id = try inode.get(current_digit);
                            } else {
                                if (current_lvl == 1) {
                                    var new_leaf = try acc.createLeaf();
                                    errdefer acc.deinitLeaf(&new_leaf);
                                    try inode.set(current_digit, new_leaf.id());
                                    try new_leaf.setParent(current_id);
                                    try new_leaf.setParentId(current_digit);
                                    try new_leaf.setParentQuotient(next_level_quot);
                                    return new_leaf;
                                } else {
                                    var new_inode = try acc.createInode();
                                    defer acc.deinitInode(&new_inode);
                                    try inode.set(current_digit, new_inode.id());
                                    try new_inode.setParentQuotient(next_level_quot);
                                    try new_inode.setLevel(next_lvl);
                                    try new_inode.setParent(current_id);
                                    try new_inode.setParentId(current_digit);
                                    current_id = new_inode.id();
                                }
                            }
                            current_lvl -= 1;
                        }
                    }
                }
            }
            return Error.InconsistentLayout;
        }

        fn growUpPath(self: *Self, level: usize) Error!void {
            const acc = self.getAccessor();

            if (try acc.getRoot() == null) {
                if (level == 0) {
                    var new_leaf = try acc.createLeaf();
                    defer acc.deinitLeaf(&new_leaf);
                    try acc.setRoot(new_leaf.id());
                } else {
                    var new_inode = try acc.createInode();
                    defer acc.deinitInode(&new_inode);
                    try new_inode.setLevel(level);
                    try acc.setRoot(new_inode.id());
                }
                return;
            }

            var root_level_init: usize = 0;

            if (try acc.getRootLevel()) |root_level| {
                if (root_level >= level) {
                    return;
                }
                root_level_init = root_level;
            }

            if (try acc.getRoot()) |root_id| {
                var current_id = root_id;

                const levels_to_add = level - root_level_init;
                for (0..levels_to_add) |_| {
                    var new_inode = try acc.createInode();
                    defer acc.deinitInode(&new_inode);

                    if (try acc.isLeaf(current_id)) {
                        var leaf = try acc.loadLeaf(current_id);
                        defer acc.deinitLeaf(&leaf);
                        try leaf.setParent(new_inode.id());
                        try new_inode.setLevel(1);
                        try new_inode.set(0, leaf.id());
                    } else {
                        var inode = try acc.loadInode(current_id);
                        defer acc.deinitInode(&inode);
                        try inode.setParent(new_inode.id());
                        const next_level = try inode.getLevel() + 1;
                        try new_inode.setLevel(next_level);
                        try new_inode.set(0, inode.id());
                    }
                    current_id = new_inode.id();
                    try acc.setRoot(current_id);
                }
            }
        }

        fn getAccessor(self: *Self) *Model.Accessor {
            return &self.model.accessor;
        }
    };
}
