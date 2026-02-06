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
    const Error = Model.Error ||
        errors.IteratorError ||
        errors.BptError;

    const FindResult = struct {
        leaf: Leaf, // leaf to insert into
        leaf_parent_pos: usize, // leaf position in parent
        leaf_weight: Weight, // weight difference to insert at. weight offset within the leaf
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

    const MovedWeight = struct {
        target_pid: Pid,
        old: Weight,
        moved: Weight,
    };

    const IteratorImpl = struct {
        const Self = @This();

        const Cursor = union(enum) {
            before_begin,
            on: usize,
            after_end,
        };

        accessor: *Accessor,
        leaf: ?Leaf = null,
        cur: Cursor,

        fn init(acc: *Accessor, leaf: Leaf, on: usize) !Self {
            var res = Self{
                .accessor = acc,
                .leaf = leaf,
                .cur = .{ .on = on },
            };

            if (try leaf.size() <= on) {
                res.cur = .after_end;
            }

            return res;
        }

        pub fn get(self: *const Self) Error!ValueView {
            try self.check();
            const val = try self.leaf.?.getValue(self.cur.on);
            return ValueView.init(try val.get());
        }

        pub fn next(self: *Self) Error!bool {
            try self.check();
            if (self.cur == .before_begin) {
                self.cur = .{ .on = 0 };
                return true;
            }
            if (self.cur.on + 1 < try self.leaf.?.size()) {
                self.cur = .{ .on = self.cur.on + 1 };
                return true;
            } else {
                try self.moveToNext();
                return self.cur != .after_end;
            }
        }

        pub fn prev(self: *Self) Error!bool {
            try self.check();
            if (self.cur == .after_end) {
                const sz = try self.leaf.?.size();
                if (sz == 0) {
                    self.cur = .before_begin;
                } else {
                    self.cur = .{ .on = sz - 1 };
                }
                return true;
            }
            if (self.cur.on > 0) {
                self.cur = .{ .on = self.cur.on - 1 };
                return true;
            } else {
                try self.moveToPrev();
                return self.cur != .before_begin;
            }
        }

        pub fn isEnd(self: *const Self) bool {
            return self.cur == .after_end;
        }

        pub fn isBegin(self: *const Self) bool {
            return self.cur == .before_begin;
        }

        pub fn deinit(self: *Self) void {
            if (self.leaf) |*leaf| {
                self.accessor.deinitLeaf(leaf);
            }
            self.leaf = null;
        }

        fn moveToNext(self: *Self) Error!void {
            try self.check();
            if (try self.leaf.?.getNext()) |next_pid| {
                var next_leaf = try self.accessor.loadLeaf(next_pid);
                errdefer self.accessor.deinitLeaf(&next_leaf);
                self.accessor.deinitLeaf(&(self.leaf.?));
                self.leaf = next_leaf;
                self.cur = .{ .on = 0 };
            } else {
                self.cur = .after_end;
            }
        }

        fn moveToPrev(self: *Self) Error!void {
            try self.check();
            if (try self.leaf.?.getPrev()) |prev_pid| {
                var prev_leaf = try self.accessor.loadLeaf(prev_pid);
                errdefer self.accessor.deinitLeaf(&prev_leaf);
                self.accessor.deinitLeaf(&(self.leaf.?));
                self.leaf = prev_leaf;
                self.cur = .{ .on = try prev_leaf.size() - 1 };
            } else {
                self.cur = .before_begin;
            }
        }

        fn check(self: *const Self) !void {
            if (self.leaf == null) {
                return Error.InvalidIterator;
            }
        }
    };

    return struct {
        const Self = @This();
        const Iterator = IteratorImpl;

        model: *Model,
        rebalance_policy: RebalancePolicy = .neighbor_share,

        pub fn init(model: *Model, rebalance_policy: RebalancePolicy) Self {
            return .{
                .model = model,
                .rebalance_policy = rebalance_policy,
            };
        }

        pub fn deinit(_: *Self) void {}

        pub fn iterator(self: *Self) Error!Iterator {
            var acc = self.getAccessor();
            const root = try acc.getRoot();
            if (root) |root_pid| {
                const leaf = try self.getLeftmostLeaf(root_pid);
                return try Iterator.init(acc, leaf, 0);
            } else {
                return Iterator{
                    .accessor = acc,
                    .leaf = null,
                    .cur = .after_end,
                };
            }
        }

        pub fn totalWeight(self: *Self) Error!Weight {
            var acc = self.getAccessor();
            const root = try acc.getRoot();
            if (root) |root_pid| {
                if (try acc.isLeaf(root_pid)) {
                    var leaf = try acc.loadLeaf(root_pid);
                    defer acc.deinitLeaf(&leaf);
                    return try leaf.totalWeight();
                } else {
                    var inode = try acc.loadInode(root_pid);
                    defer acc.deinitInode(&inode);
                    return try inode.totalWeight();
                }
            } else {
                return 0;
            }
        }

        pub fn insert(self: *Self, where: Weight, value: Value) Error!bool {
            var accessor = self.getAccessor();
            const root = try accessor.getRoot();
            if (root) |rpid| {
                var find_result = try self.findLeafForWeight(rpid, where);
                defer accessor.deinitLeaf(&find_result.leaf);

                var value_view = try ValueView.init(value);
                defer value_view.deinit();

                if (try find_result.leaf.canInsertWeight(find_result.leaf_weight)) {
                    try find_result.leaf.insertWeight(find_result.leaf_weight, try value_view.get());
                    try self.leafFixParentWeight(&find_result.leaf);
                } else {
                    if (!try self.leafTryShareNeighbor(&find_result, value)) {
                        try self.leafHandleOverflowImpl(&find_result.leaf, find_result.leaf_weight, try value_view.get());
                    }
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
                        .leaf_weight = weight - accumulated,
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

        fn leafFindRightSibling(self: *Self, leaf: *const Leaf) Error!?ParentInfo {
            var acc = self.getAccessor();
            var pinfo = try self.leafParentInfo(leaf);
            if (pinfo) |*parent_info| {
                errdefer acc.deinitInode(&parent_info.inode);
                if (parent_info.pos + 1 < try parent_info.inode.size()) {
                    parent_info.pos += 1;
                    return parent_info.*;
                }
            }
            return null;
        }

        fn leafFindLeftSibling(self: *Self, leaf: *const Leaf) Error!?ParentInfo {
            var acc = self.getAccessor();
            var pinfo = try self.leafParentInfo(leaf);
            if (pinfo) |*parent_info| {
                errdefer acc.deinitInode(&parent_info.inode);
                if (parent_info.pos > 0) {
                    parent_info.pos -= 1;
                    return parent_info.*;
                }
            }
            return null;
        }

        fn inodeFindRightSibling(self: *Self, inode: *const Inode) Error!?ParentInfo {
            var acc = self.getAccessor();
            var pinfo = try self.inodeParentInfo(inode);
            if (pinfo) |*parent_info| {
                errdefer acc.deinitInode(&parent_info.inode);
                if (parent_info.pos + 1 < try parent_info.inode.size()) {
                    parent_info.pos += 1;
                    return parent_info.*;
                }
            }
            return null;
        }

        fn inodeFindLeftSibling(self: *Self, inode: *const Inode) Error!?ParentInfo {
            var acc = self.getAccessor();
            var pinfo = try self.inodeParentInfo(inode);
            if (pinfo) |*parent_info| {
                errdefer acc.deinitInode(&parent_info.inode);
                if (parent_info.pos > 0) {
                    parent_info.pos -= 1;
                    return parent_info.*;
                }
            }
            return null;
        }

        /// split, handle overflow
        fn leafHandleOverflowImpl(self: *Self, leaf: *Leaf, leaf_weight: Weight, val: Value) Error!void {
            var acc = self.getAccessor();
            var sres = try self.leafHandleOverflow(leaf);
            defer acc.deinitLeaf(&sres.right);
            if (leaf_weight < sres.left_weight) {
                try leaf.insertWeight(leaf_weight, val);
                try self.leafFixParentWeight(leaf);
            } else {
                try sres.right.insertWeight(leaf_weight - sres.left_weight, val);
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
                    if (!try self.inodeTryShareNeighbor(&pinode, ppos)) {
                        try self.inodeHandleOverflow(&pinode);
                    }
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
                    if (!try self.inodeTryShareNeighbor(&pinode, ppos)) {
                        try self.inodeHandleOverflow(&pinode);
                    }
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

        // borrowing and giving values between neighbors for rebalancing

        fn leafTryBorrowFromRight(self: *Self, leaf: *Leaf) Error!?MovedWeight {
            var acc = self.getAccessor();
            if (try self.leafFindRightSibling(leaf)) |*sibling_info| {
                defer acc.deinitInode(&sibling_info.inode);

                const rpid = try sibling_info.inode.getChild(sibling_info.pos);
                var right = acc.loadLeaf(try sibling_info.inode.getChild(rpid));
                defer acc.deinitLeaf(&right);

                return try self.leafTryBorrowFromRightImpl(leaf, &right, sibling_info);
            }
            return null;
        }

        fn leafTryBorrowFromRightImpl(_: *const Self, leaf: *Leaf, right: *Leaf, sibling_info: *ParentInfo) Error!?MovedWeight {
            const cap = try right.capacity();
            const rsz = try right.size();
            if (rsz > (cap / 2)) {
                var val = try right.getValue(0);
                defer val.deinit();

                const moved_weight = try val.weight();
                const lsz = try leaf.size();
                try leaf.insertAt(lsz, try val.get());

                try right.removeAt(0);

                const my_pos = sibling_info.pos - 1;
                const my_weight = try sibling_info.inode.getWeight(my_pos);
                try sibling_info.inode.updateWeight(my_pos, my_weight + moved_weight);

                const right_weight = try sibling_info.inode.getWeight(sibling_info.pos);
                try sibling_info.inode.updateWeight(sibling_info.pos, right_weight - moved_weight);
                return MovedWeight{
                    .target_pid = right.id(),
                    .old = right_weight,
                    .moved = moved_weight,
                };
            }
            return null;
        }

        fn leafTryBorrowFromLeft(self: *Self, leaf: *Leaf) Error!?MovedWeight {
            var acc = self.getAccessor();
            if (try self.leafFindLeftSibling(leaf)) |*sibling_info| {
                defer acc.deinitInode(&sibling_info.inode);

                const lpid = try sibling_info.inode.getChild(sibling_info.pos);
                var left = acc.loadLeaf(lpid);
                defer acc.deinitLeaf(&left);

                return try self.leafTryBorrowFromLeftImpl(leaf, &left, sibling_info);
            }
            return null;
        }

        fn leafTryBorrowFromLeftImpl(_: *const Self, leaf: *Leaf, left: *Leaf, sibling_info: *ParentInfo) Error!?MovedWeight {
            const cap = try left.capacity();
            const lsz = try left.size();
            if (lsz > (cap / 2)) {
                var val = try left.getValue(lsz - 1);
                defer val.deinit();

                const moved_weight = try val.weight();
                try leaf.insertAt(0, try val.get());
                try left.removeAt(lsz - 1);

                const my_pos = sibling_info.pos + 1;
                const my_weight = try sibling_info.inode.getWeight(my_pos);
                try sibling_info.inode.updateWeight(my_pos, my_weight + moved_weight);

                const left_weight = try sibling_info.inode.getWeight(sibling_info.pos);
                try sibling_info.inode.updateWeight(sibling_info.pos, left_weight - moved_weight);
                return MovedWeight{
                    .target_pid = left.id(),
                    .old = left_weight,
                    .moved = moved_weight,
                };
            }
            return null;
        }

        fn leafTryGiveToRight(self: *Self, leaf: *Leaf, additional_entry: usize) Error!?MovedWeight {
            var acc = self.getAccessor();
            var parent_info = try self.leafFindRightSibling(leaf);
            if (parent_info) |*sibling_info| {
                defer acc.deinitInode(&sibling_info.inode);

                const rpos = sibling_info.pos;
                const rpid = try sibling_info.inode.getChild(rpos);

                var right = try acc.loadLeaf(rpid);
                defer acc.deinitLeaf(&right);

                sibling_info.pos -= 1; // make it point to self
                const right_weight = try right.totalWeight();

                const right_sz = try right.size();
                const right_cap = try right.capacity();
                if (right_sz < (right_cap - additional_entry)) {
                    var moved = try self.leafTryBorrowFromLeftImpl(&right, leaf, sibling_info);
                    if (moved) |*m| {
                        m.target_pid = right.id();
                        m.old = right_weight;
                        return m.*;
                    }
                }
            }
            return null;
        }

        fn leafTryGiveToLeft(self: *Self, leaf: *Leaf, additional_entry: usize) Error!?MovedWeight {
            var acc = self.getAccessor();
            var parent_info = try self.leafFindLeftSibling(leaf);
            if (parent_info) |*sibling_info| {
                defer acc.deinitInode(&sibling_info.inode);

                const lpos = sibling_info.pos;
                const lpid = try sibling_info.inode.getChild(lpos);

                var left = try acc.loadLeaf(lpid);
                defer acc.deinitLeaf(&left);

                sibling_info.pos += 1; // make it point to self
                const left_weight = try left.totalWeight();

                const left_sz = try left.size();
                const left_cap = try left.capacity();
                if (left_sz < (left_cap - additional_entry)) {
                    var moved = try self.leafTryBorrowFromRightImpl(&left, leaf, sibling_info);
                    if (moved) |*m| {
                        m.target_pid = left.id();
                        m.old = left_weight;
                        return m.*;
                    }
                }
            }
            return null;
        }

        fn leafTryShareNeighbor(self: *Self, fres: *FindResult, val: Value) Error!bool {
            if (self.rebalance_policy != .neighbor_share) {
                return false;
            }

            const leaf = &fres.leaf;
            const l_sz = try leaf.size();
            const l_cap = try leaf.capacity();

            // in page model it's possible to have size > capacity with variadic sized entries,
            if (l_sz > l_cap) { // can not share in this case and have to split
                return false;
            }

            var acc = self.getAccessor();
            const pos_in_leaf = fres.node_pos.pos;
            const diff_in_leaf = fres.node_pos.diff;
            const is_first = pos_in_leaf == 0;
            const is_last = pos_in_leaf == (try leaf.size() - 1);
            const additional_entry: usize = if (diff_in_leaf == 0) 0 else 1;

            if (l_cap - l_sz < additional_entry) {
                // not enough space even with sharing
                // as we need to split an entry in the leaf to insert the new value
                return false;
            }

            const additional_for_right = if (is_last) 1 + additional_entry else 0;
            const additional_for_left = if (is_first) 1 + additional_entry else 0;

            if (try self.leafTryGiveToRight(leaf, additional_for_right)) |m| {
                if (is_last) {
                    var right = try acc.loadLeaf(m.target_pid);
                    defer acc.deinitLeaf(&right);
                    const current_weight = try leaf.totalWeight();
                    const new_diff = fres.leaf_weight - current_weight;
                    try right.insertWeight(new_diff, val);
                    try self.leafFixParentWeight(&right);
                } else {
                    try leaf.insertWeight(fres.leaf_weight, val);
                    try self.leafFixParentWeight(leaf);
                }
                return true;
            } else if (try self.leafTryGiveToLeft(leaf, additional_for_left)) |m| {
                if (is_first) {
                    var left = try acc.loadLeaf(m.target_pid);
                    defer acc.deinitLeaf(&left);
                    const new_diff = m.old + fres.node_pos.diff;
                    try left.insertWeight(new_diff, val);
                    try self.leafFixParentWeight(&left);
                } else {
                    const new_diff = fres.leaf_weight - m.moved;
                    try leaf.insertWeight(new_diff, val);
                    try self.leafFixParentWeight(leaf);
                }
                return true;
            }

            return false;
        }

        fn inodeTryBorrowFromRight(self: *Self, inode: *Inode) Error!?MovedWeight {
            var acc = self.getAccessor();
            if (try self.inodeFindRightSibling(inode)) |*sibling_info| {
                defer acc.deinitInode(&sibling_info.inode);

                const rpid = try sibling_info.inode.getChild(sibling_info.pos);
                var right = acc.loadInode(rpid);
                defer acc.deinitInode(&right);
                return try self.inodeTryBorrowfromRightImpl(inode, &right, sibling_info);
            }
            return null;
        }

        fn inodeTryBorrowFromRightImpl(self: *Self, inode: *Inode, right: *Inode, sibling_info: *ParentInfo) Error!?MovedWeight {
            const cap = try right.capacity();
            const rsz = try right.size();
            if (rsz > (cap / 2)) {
                const inode_sz = try inode.size();
                const old_weight = try right.totalWeight();
                const first_child = try right.getChild(0);
                const first_weight = try right.getWeight(0);

                try inode.insertChild(inode_sz, first_child, first_weight);
                try self.setChildParent(first_child, inode.id());
                try right.removeAt(0);

                const my_pos = sibling_info.pos - 1;
                const my_weight = try sibling_info.inode.getWeight(my_pos);
                try sibling_info.inode.updateWeight(my_pos, my_weight + first_weight);

                const right_weight = try sibling_info.inode.getWeight(sibling_info.pos);
                try sibling_info.inode.updateWeight(sibling_info.pos, right_weight - first_weight);
                return MovedWeight{
                    .target_pid = right.id(),
                    .old = old_weight,
                    .moved = first_weight,
                };
            }
            return null;
        }

        fn inodeTryBorrowFromLeft(self: *Self, inode: *Inode) Error!?MovedWeight {
            var acc = self.getAccessor();
            if (try self.inodeFindLeftSibling(inode)) |*sibling_info| {
                defer acc.deinitInode(&sibling_info.inode);

                const lpid = try sibling_info.inode.getChild(sibling_info.pos);
                var left = acc.loadInode(lpid);
                defer acc.deinitInode(&left);
                return try self.inodeTryBorrowFromLeftImpl(inode, &left, sibling_info);
            }
            return null;
        }

        fn inodeTryBorrowFromLeftImpl(self: *Self, inode: *Inode, left: *Inode, sibling_info: *ParentInfo) Error!?MovedWeight {
            const cap = try left.capacity();
            const lsz = try left.size();
            if (lsz > (cap / 2)) {
                const old_weight = try left.totalWeight();
                const last_child = try left.getChild(lsz - 1);
                const last_weight = try left.getWeight(lsz - 1);

                try inode.insertChild(0, last_child, last_weight);
                try self.setChildParent(last_child, inode.id());
                try left.removeAt(lsz - 1);

                const my_pos = sibling_info.pos + 1;
                const my_weight = try sibling_info.inode.getWeight(my_pos);
                try sibling_info.inode.updateWeight(my_pos, my_weight + last_weight);

                const left_weight = try sibling_info.inode.getWeight(sibling_info.pos);
                try sibling_info.inode.updateWeight(sibling_info.pos, left_weight - last_weight);
                return MovedWeight{
                    .target_pid = left.id(),
                    .old = old_weight,
                    .moved = last_weight,
                };
            }
            return null;
        }

        fn inodeTryGiveToRight(self: *Self, inode: *Inode, additional_entry: usize) Error!?MovedWeight {
            var acc = self.getAccessor();
            var parent_info = try self.inodeFindRightSibling(inode);
            if (parent_info) |*sibling_info| {
                defer acc.deinitInode(&sibling_info.inode);

                const rpos = sibling_info.pos;
                const rpid = try sibling_info.inode.getChild(rpos);

                var right = try acc.loadInode(rpid);
                defer acc.deinitInode(&right);

                sibling_info.pos -= 1; // make it point to self
                const right_weight = try right.totalWeight();

                const right_sz = try right.size();
                const right_cap = try right.capacity();
                if (right_sz < (right_cap - additional_entry)) {
                    var moved = try self.inodeTryBorrowFromLeftImpl(&right, inode, sibling_info);
                    if (moved) |*m| {
                        m.target_pid = right.id();
                        m.old = right_weight;
                        return m.*;
                    }
                }
            }
            return null;
        }

        fn inodeTryGiveToLeft(self: *Self, inode: *Inode, additional_entry: usize) Error!?MovedWeight {
            var acc = self.getAccessor();
            var parent_info = try self.inodeFindLeftSibling(inode);
            if (parent_info) |*sibling_info| {
                defer acc.deinitInode(&sibling_info.inode);

                const lpos = sibling_info.pos;
                const lpid = try sibling_info.inode.getChild(lpos);

                var left = try acc.loadInode(lpid);
                defer acc.deinitInode(&left);

                sibling_info.pos += 1; // make it point to self
                const left_weight = try left.totalWeight();

                const left_sz = try left.size();
                const left_cap = try left.capacity();
                if (left_sz < (left_cap - additional_entry)) {
                    var moved = try self.inodeTryBorrowFromRightImpl(&left, inode, sibling_info);
                    if (moved) |*m| {
                        m.target_pid = left.id();
                        m.old = left_weight;
                        return m.*;
                    }
                }
            }
            return null;
        }

        fn inodeTryShareNeighbor(self: *Self, inode: *Inode, target_pos: usize) Error!bool {
            if (self.rebalance_policy != .neighbor_share) {
                return false;
            }

            const is_first = target_pos == 0;
            const is_last = target_pos == (try inode.size() - 1);

            const additional_for_right: usize = if (is_last) 1 else 0;
            const additional_for_left: usize = if (is_first) 1 else 0;

            if (try self.inodeTryGiveToRight(inode, additional_for_right)) |_| {
                return true;
            } else if (try self.inodeTryGiveToLeft(inode, additional_for_left)) |_| {
                return true;
            }

            return false;
        }

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

        fn getLeftmostLeaf(self: *Self, from: Pid) Error!Leaf {
            var acc = self.getAccessor();
            var current_pid = from;
            while (true) {
                if (try acc.isLeaf(current_pid)) {
                    return try acc.loadLeaf(current_pid);
                } else {
                    var inode = try acc.loadInode(current_pid);
                    defer acc.deinitInode(&inode);
                    current_pid = try inode.getChild(0);
                }
            }
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

                // // Print weights
                // printDepth(depth);
                // std.debug.print("  Weights: [", .{});
                // for (0..num_children) |i| {
                //     if (i > 0) std.debug.print(", ", .{});
                //     std.debug.print("{}", .{try inode.getWeight(i)});
                // }
                // std.debug.print("]\n", .{});

                // Print children IDs
                printDepth(depth);
                std.debug.print("  Children: [", .{});
                for (0..num_children) |i| {
                    if (i > 0) std.debug.print(", ", .{});
                    std.debug.print("(#{} w:{})", .{ try inode.getChild(i), try inode.getWeight(i) });
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
