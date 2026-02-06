const std = @import("std");
const core = @import("../core/core.zig");
const errors = @import("../core/errors.zig");

pub const RebalancePolicy = enum {
    force_split,
    neighbor_share,
};

pub fn WeightedBpt(comptime ModelT: type) type {
    const Model = ModelT;
    const Accessor = Model.AccessorType;
    const Weight = Model.WeightType;
    const ValueView = Model.ValueViewType;
    const Value = Model.ValueType;
    const NodePosition = Model.NodePositionType;
    const Pid = Model.PidType;

    const Leaf = Model.LeafType;
    const Inode = Model.InodeType;
    const Error = Model.Error || errors.BptError;

    const FindResult = struct {
        leaf: Leaf, // leaf to insert into
        leaf_parent_pos: usize, // leaf position in parent
        diff: Weight, // weight difference to insert at. weight offset within the leaf
        node_pos: NodePosition,
    };

    const ParentInfo = struct {
        inode: Inode,
        pos: usize,
    };

    const LeafSplitResult = struct {
        right: Leaf,
        right_weight: Weight,
        left_weight: Weight,
    };

    const InodeSplitResult = struct {
        right: Inode,
        right_weight: Weight,
        left_weight: Weight,
    };

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

        pub fn insert(self: *Self, where: Weight, value: Value) Error!bool {
            var accessor = self.getAccessor();
            const root = try accessor.getRoot();
            if (root) |rpid| {
                var find_result = try self.findLeafForWeight(rpid, where);
                defer accessor.deinitLeaf(&find_result.leaf);

                var value_view = try ValueView.init(value);
                defer value_view.deinit();

                if (try find_result.leaf.canInsertWeight(find_result.diff)) {
                    try find_result.leaf.insertWeight(find_result.diff, try value_view.get());
                    try self.leafFixParentWeight(&find_result.leaf);
                } else {
                    try self.leafHandleOverflowImpl(&find_result.leaf, find_result.diff, try value_view.get());
                }
                return true;
            } else {
                var leaf = try accessor.createLeaf();
                defer accessor.deinitLeaf(&leaf);
                try leaf.insertAt(0, value);
                try accessor.setRoot(leaf.id());
                return true;
            }
        }

        pub fn dump(self: *Self) void {
            var acc = self.getAccessor();
            const root = acc.getRoot() catch |err| {
                std.debug.print("Error getting root: {any}\n", .{err});
                return;
            };
            if (root) |root_pid| {
                self.dumpNode(root_pid, 0) catch |err| {
                    std.debug.print("Error dumping node: {any}\n", .{err});
                };
            } else {
                std.debug.print("Empty tree\n", .{});
            }
        }

        /// implementation fns. non public
        fn getAccessor(self: *Self) *Accessor {
            return self.model.getAccessor();
        }

        fn leafFixParentWeight(self: *Self, leaf: *const Leaf) Error!void {
            var acc = self.getAccessor();
            var pinfo = try self.leafParentInfo(leaf);
            if (pinfo) |*parent_info| {
                defer acc.deinitInode(&parent_info.inode);
                const leaf_weight = try leaf.totalWeight();
                try parent_info.inode.updateWeight(parent_info.pos, leaf_weight);
                try self.inodeFixParentWeight(&parent_info.inode);
            }
        }

        fn inodeFixParentWeight(self: *Self, inode: *const Inode) Error!void {
            var acc = self.getAccessor();
            var pinfo = try self.inodeParentInfo(inode);
            if (pinfo) |*parent_info| {
                defer acc.deinitInode(&parent_info.inode);
                const inode_weight = try inode.totalWeight();
                try parent_info.inode.updateWeight(parent_info.pos, inode_weight);
                try self.inodeFixParentWeight(&parent_info.inode);
            }
        }

        fn findLeafForWeight(self: *Self, from: Pid, weight: Weight) Error!FindResult {
            var acc = self.getAccessor();
            var current_pid = from;
            var accumulated: Weight = 0;
            var parent_pos: usize = 0;
            while (true) {
                if (try acc.isLeaf(current_pid)) {
                    var leaf = try acc.loadLeaf(current_pid);
                    errdefer acc.deinitLeaf(&leaf);
                    const leaf_pos = try leaf.selectPos(weight - accumulated);
                    return FindResult{
                        .leaf = leaf,
                        .leaf_parent_pos = parent_pos,
                        .diff = weight - accumulated,
                        .node_pos = leaf_pos,
                    };
                } else {
                    var inode = try acc.loadInode(current_pid);
                    defer acc.deinitInode(&inode);
                    const pos = try inode.selectPos(weight - accumulated);
                    parent_pos = pos.pos;
                    accumulated += pos.accumulated;
                    current_pid = try inode.getChild(pos.pos);
                }
            }
        }

        fn leafParentInfo(self: *Self, leaf: *const Leaf) Error!?ParentInfo {
            var acc = self.getAccessor();
            if (try leaf.getParent()) |ppid| {
                var parent = try acc.loadInode(ppid);
                errdefer acc.deinitInode(&parent);
                const pos = try childIdInParent(&parent, leaf.id());
                return ParentInfo{
                    .inode = parent,
                    .pos = pos,
                };
            }
            return null; // no parent, root leaf
        }

        fn inodeParentInfo(self: *Self, inode: *const Inode) Error!?ParentInfo {
            var acc = self.getAccessor();
            if (try inode.getParent()) |ppid| {
                var parent = try acc.loadInode(ppid);
                errdefer acc.deinitInode(&parent);
                const pos = try childIdInParent(&parent, inode.id());
                return ParentInfo{
                    .inode = parent,
                    .pos = pos,
                };
            }
            return null; // no parent, root inode
        }

        /// split, handle overflow
        fn leafHandleOverflowImpl(self: *Self, leaf: *Leaf, weight_diff: Weight, val: Value) Error!void {
            var acc = self.getAccessor();
            var sres = try self.leafHandleOverflow(leaf);
            defer acc.deinitLeaf(&sres.right);
            if (weight_diff < sres.left_weight) {
                try leaf.insertWeight(weight_diff, val);
                try self.leafFixParentWeight(leaf);
            } else {
                try sres.right.insertWeight(weight_diff - sres.left_weight, val);
                try self.leafFixParentWeight(&sres.right);
            }
        }

        fn leafHandleOverflow(self: *Self, leaf: *Leaf) Error!LeafSplitResult {
            var acc = self.getAccessor();
            var split_result = try self.leafSplit(leaf);
            errdefer acc.deinitLeaf(&split_result.right);

            if (try leaf.getParent()) |ppid| {
                var pinode = try acc.loadInode(ppid);
                defer acc.deinitInode(&pinode);
                var ppos = try childIdInParent(&pinode, leaf.id());

                if (!try pinode.canInsertAt(ppos, split_result.right_weight)) {
                    try self.inodeHandleOverflow(&pinode);
                }

                const new_ppid = (try leaf.getParent()).?;
                acc.deinitInode(&pinode);
                pinode = try acc.loadInode(new_ppid);
                ppos = try childIdInParent(&pinode, leaf.id());

                try split_result.right.setParent(new_ppid);
                try pinode.updateWeight(ppos, split_result.left_weight);
                try pinode.insertChild(ppos + 1, split_result.right.id(), split_result.right_weight);
                try self.inodeFixParentWeight(&pinode);
            } else { // new root
                var new_root = try acc.createInode();
                defer acc.deinitInode(&new_root);
                try new_root.insertChild(0, leaf.id(), split_result.left_weight);
                try new_root.insertChild(1, split_result.right.id(), split_result.right_weight);
                try acc.setRoot(new_root.id());
                try leaf.setParent(new_root.id());
                try split_result.right.setParent(new_root.id());
            }

            return split_result;
        }

        fn leafSplit(self: *Self, leaf: *Leaf) Error!LeafSplitResult {
            const cur_sz = try leaf.size();
            const mid = cur_sz / 2;
            const to_reduce = cur_sz - mid;
            var acc = self.getAccessor();

            var right = try acc.createLeaf();
            errdefer acc.deinitLeaf(&right);

            try right.setParent(try leaf.getParent());
            try right.setPrev(leaf.id());
            try right.setNext(try leaf.getNext());
            if (try leaf.getNext()) |n| {
                var next_leaf = try acc.loadLeaf(n);
                defer acc.deinitLeaf(&next_leaf);
                try next_leaf.setPrev(right.id());
            }
            try leaf.setNext(right.id());

            var right_weight: Weight = 0;
            for (mid..cur_sz, 0..) |from, to| {
                var val = try leaf.getValue(from);
                defer val.deinit();
                right_weight += try val.weight();
                try right.insertAt(to, try val.get());
            }

            for (0..to_reduce) |_| {
                try leaf.removeAt(mid);
            }

            return .{
                .right = right,
                .right_weight = right_weight,
                .left_weight = try leaf.totalWeight(),
            };
        }

        fn inodeHandleOverflow(self: *Self, inode: *Inode) Error!void {
            var acc = self.getAccessor();
            const ppid = try inode.getParent();
            var split_result = try self.inodeSplit(inode);
            defer acc.deinitInode(&split_result.right);

            if (ppid) |parent_pid| {
                var pinode = try acc.loadInode(parent_pid);
                defer acc.deinitInode(&pinode);
                var ppos = try childIdInParent(&pinode, inode.id());

                if (!try pinode.canInsertAt(ppos, split_result.right_weight)) {
                    try self.inodeHandleOverflow(&pinode);
                }

                const new_ppid = (try inode.getParent()).?;
                acc.deinitInode(&pinode);
                pinode = try acc.loadInode(new_ppid);
                ppos = try childIdInParent(&pinode, inode.id());

                try split_result.right.setParent(new_ppid);
                try pinode.updateWeight(ppos, split_result.left_weight);
                try pinode.insertChild(ppos + 1, split_result.right.id(), split_result.right_weight);
                try self.inodeFixParentWeight(&pinode);
            } else { // new root
                var new_root = try acc.createInode();
                defer acc.deinitInode(&new_root);
                try new_root.insertChild(0, inode.id(), split_result.left_weight);
                try new_root.insertChild(1, split_result.right.id(), split_result.right_weight);
                try acc.setRoot(new_root.id());

                try inode.setParent(new_root.id());
                try split_result.right.setParent(new_root.id());
            }
        }

        fn inodeSplit(self: *Self, inode: *Inode) Error!InodeSplitResult {
            const cur_sz = try inode.size();
            const mid = cur_sz / 2;
            const to_reduce = cur_sz - mid;
            var acc = self.getAccessor();
            var right = try acc.createInode();
            errdefer acc.deinitInode(&right);
            var rweight: Weight = 0;

            try right.setParent(try inode.getParent());
            for (mid..cur_sz, 0..) |from, to| {
                const child = try inode.getChild(from);
                const weight = try inode.getWeight(from);
                rweight += weight;
                try right.insertChild(to, child, weight);
                try self.setChildParent(child, right.id());
            }
            for (0..to_reduce) |_| {
                try inode.removeAt(mid);
            }

            return .{
                .right = right,
                .right_weight = rweight,
                .left_weight = try inode.totalWeight(),
            };
        }

        // borrowing and giving values between neighbors for rebalancing, TODO

        ////

        ///
        fn setChildParent(self: *Self, child_pid: Pid, parent_pid: Pid) Error!void {
            var acc = self.getAccessor();
            if (try acc.isLeaf(child_pid)) {
                var leaf = try acc.loadLeaf(child_pid);
                defer acc.deinitLeaf(&leaf);
                try leaf.setParent(parent_pid);
            } else {
                var inode = try acc.loadInode(child_pid);
                defer acc.deinitInode(&inode);
                try inode.setParent(parent_pid);
            }
        }

        fn childIdInParent(parent: *const Inode, child_pid: Pid) Error!usize {
            for (0..try parent.size()) |entry| {
                if (try parent.getChild(entry) == child_pid) {
                    return entry;
                }
            }
            return Error.ChildNotFoundInParent;
        }

        fn printDepth(d: usize) void {
            for (0..d) |_| {
                std.debug.print("  ", .{});
            }
        }

        fn dumpNode(self: *Self, pid: Pid, depth: usize) Error!void {
            var acc = self.getAccessor();
            if (try acc.isLeaf(pid)) {
                var leaf = try acc.loadLeaf(pid);
                defer acc.deinitLeaf(&leaf);

                // Print leaf header
                printDepth(depth);
                std.debug.print("LEAF #{} w:{}\n", .{ leaf.id(), try leaf.totalWeight() });

                // Print navigation info
                printDepth(depth);
                std.debug.print("  Parent: ", .{});
                if (try leaf.getParent()) |p| {
                    std.debug.print("{}", .{p});
                } else {
                    std.debug.print("none", .{});
                }
                std.debug.print(", Prev: ", .{});
                if (try leaf.getPrev()) |p| {
                    std.debug.print("{}", .{p});
                } else {
                    std.debug.print("none", .{});
                }
                std.debug.print(", Next: ", .{});
                if (try leaf.getNext()) |n| {
                    std.debug.print("{}", .{n});
                } else {
                    std.debug.print("none", .{});
                }
                std.debug.print("\n", .{});

                // Print values
                printDepth(depth);
                std.debug.print("  Values: {}\n", .{try leaf.size()});
                for (0..try leaf.size()) |i| {
                    var val = try leaf.getValue(i);
                    defer val.deinit();
                    printDepth(depth);
                    std.debug.print("    [{}] weight={} val='{s}'\n", .{ i, try val.weight(), try val.get() });
                }
            } else {
                var inode = try acc.loadInode(pid);
                defer acc.deinitInode(&inode);

                // Print inode header
                printDepth(depth);
                const num_children = try inode.size();
                std.debug.print("INODE #{} {} children w:{}\n", .{ inode.id(), num_children, try inode.totalWeight() });

                // print Parent
                printDepth(depth);
                std.debug.print("  Parent: ", .{});
                if (try inode.getParent()) |p| {
                    std.debug.print("{}", .{p});
                } else {
                    std.debug.print("none", .{});
                }
                std.debug.print("\n", .{});

                // Print weights
                printDepth(depth);
                std.debug.print("  Weights: [", .{});
                for (0..num_children) |i| {
                    if (i > 0) std.debug.print(", ", .{});
                    std.debug.print("{}", .{try inode.getWeight(i)});
                }
                std.debug.print("]\n", .{});

                // Print children IDs
                printDepth(depth);
                std.debug.print("  Children: [", .{});
                for (0..num_children) |i| {
                    if (i > 0) std.debug.print(", ", .{});
                    std.debug.print("{}", .{try inode.getChild(i)});
                }
                std.debug.print("]\n", .{});

                // Recursively dump all children
                for (0..num_children) |i| {
                    try self.dumpNode(try inode.getChild(i), depth + 1);
                }
            }
        }
    };
}
