const std = @import("std");

pub const RebalancePolicy = enum {
    force_split,
    neighbor_share,
};

pub fn Bpt(comptime ModelT: type) type {
    return struct {
        model: *ModelT,
        rebalance_policy: RebalancePolicy = .neighbor_share,

        const Self = @This();
        // model types
        pub const KeyLikeType = ModelT.KeyLikeType;
        pub const KeyOutType = ModelT.KeyOutType;
        pub const KeyBorrowType = ModelT.KeyBorrowType;

        pub const ValueInType = ModelT.ValueInType;
        pub const ValueOutType = ModelT.ValueOutType;
        pub const ValueBorrowType = ModelT.ValueBorrowType;
        pub const NodedIdType = ModelT.NodedIdType;

        pub const InodeType = ModelT.InodeType;
        pub const LeafType = ModelT.LeafType;

        pub const Iterator = struct {
            const ItrSelf = @This();

            const Cursor = union(enum) {
                before_first,
                on: usize,
                after_last,
            };

            const Result = struct {
                key: KeyOutType,
                value: ValueOutType,
                node_id: NodedIdType,
                pos: usize,
            };

            pub fn init(model: ?*ModelT, node_id: NodedIdType, cursor: Cursor) !ItrSelf {
                var res = ItrSelf{
                    .model = model,
                    .node = null,
                    .cursor = cursor,
                };
                if (model) |mod| {
                    var m = mod;
                    const accessor = m.getAccessor();
                    if (try accessor.loadLeaf(node_id)) |node| {
                        res.node = node;
                    }
                }
                return res;
            }

            pub fn get(self: *const ItrSelf) !?Result {
                if (self.node) |node| {
                    return switch (self.cursor) {
                        .on => |i| blk: {
                            if (i >= node.size()) {
                                break :blk null;
                            }
                            break :blk Result{
                                .key = try node.getKey(i),
                                .value = try node.getValue(i),
                                .node_id = node.id(),
                                .pos = i,
                            };
                        },
                        else => null,
                    };
                }
                return null;
            }

            pub fn next(self: *ItrSelf) !?Result {
                if (self.node) |node| {
                    switch (self.cursor) {
                        .before_first => {
                            if (node.size() > 0) {
                                self.cursor = .{ .on = 0 };
                            } else {
                                if (!try self.moveNext(node.getNext())) {
                                    self.cursor = .after_last;
                                    return null;
                                }
                            }
                        },
                        .on => |i| {
                            const next_idx = i + 1;
                            if (next_idx >= node.size()) {
                                if (!try self.moveNext(node.getNext())) {
                                    self.cursor = .after_last;
                                    return null;
                                }
                            } else {
                                self.cursor = .{ .on = next_idx };
                            }
                        },
                        .after_last => return null,
                    }
                    return self.get();
                }
                return null;
            }

            pub fn prev(self: *ItrSelf) !?Result {
                if (self.node) |node| {
                    switch (self.cursor) {
                        .before_first => return null,
                        .on => |i| {
                            if (i == 0) {
                                if (!try self.movePrev(node.getPrev())) {
                                    self.cursor = .before_first;
                                    return null;
                                }
                            } else {
                                self.cursor = .{ .on = i - 1 };
                            }
                        },
                        .after_last => {
                            if (node.size() > 0) {
                                self.cursor = .{ .on = node.size() - 1 };
                            } else {
                                if (!try self.movePrev(node.getPrev())) {
                                    self.cursor = .before_first;
                                    return null;
                                }
                            }
                        },
                    }
                    return self.get();
                }
                return null;
            }

            pub fn deinit(self: ItrSelf) void {
                if (self.model) |model| {
                    model.getAccessor().deinitLeaf(self.node);
                }
            }

            fn moveNext(self: *ItrSelf, next_id: ?NodedIdType) !bool {
                if (self.model) |cmodel| {
                    var model = cmodel;
                    var pid_opt = next_id;
                    const accessor = model.getAccessor();
                    while (pid_opt) |pid| {
                        if (try accessor.loadLeaf(pid)) |next_node| {
                            if (next_node.size() > 0) {
                                accessor.deinitLeaf(self.node);
                                self.node = next_node;
                                self.cursor = .{ .on = 0 };
                                return true;
                            }
                            pid_opt = next_node.getNext();
                            accessor.deinitLeaf(next_node);
                            continue;
                        } else {
                            break;
                        }
                    }
                }
                return false;
            }

            fn movePrev(self: *ItrSelf, prev_id: ?NodedIdType) !bool {
                if (self.model) |cmodel| {
                    var model = cmodel;
                    var pid_opt = prev_id;
                    const accessor = model.getAccessor();
                    while (pid_opt) |pid| {
                        if (try accessor.loadLeaf(pid)) |prev_node| {
                            if (prev_node.size() > 0) {
                                accessor.deinitLeaf(self.node);
                                self.node = prev_node;
                                self.cursor = .{ .on = prev_node.size() - 1 };
                                return true;
                            }
                            pid_opt = prev_node.getPrev();
                            accessor.deinitLeaf(prev_node);
                            continue;
                        } else {
                            break;
                        }
                    }
                }
                return false;
            }

            model: ?*ModelT = null,
            node: ?LeafType,
            cursor: Cursor = .before_first,
        };

        pub fn init(model: *ModelT, repalance_policy: RebalancePolicy) Self {
            return Self{ .model = model, .rebalance_policy = repalance_policy };
        }

        pub fn deinit(_: Self) void {
            // nothing to do for now :)
        }

        pub fn iterator(self: *const Self) !?Iterator {
            const accessor = self.model.getAccessor();
            if (accessor.getRoot()) |root_id| {
                if (try self.getLeftMostLeafId(root_id)) |left_id| {
                    return try Iterator.init(self.model, left_id, .before_first);
                }
            }
            return null;
        }

        pub fn iteratorFromEnd(self: *const Self) !?Iterator {
            const accessor = self.model.getAccessor();
            if (accessor.getRoot()) |root_id| {
                if (try self.getRightMostLeafId(root_id)) |right_id| {
                    return try Iterator.init(self.model, right_id, .after_last);
                }
            }
            return null;
        }

        pub fn find(self: *const Self, key: KeyLikeType) !?Iterator {
            const accessor = self.model.getAccessor();
            if (accessor.getRoot()) |root| {
                const search = try self.findLeafWith(key, root);
                if (search.leaf) |leaf_const| {
                    var leaf = leaf_const;
                    defer accessor.deinitLeaf(leaf);
                    if (search.found) {
                        return try Iterator.init(self.model, leaf.id(), .{ .on = search.position });
                    }
                }
            }
            return null;
        }

        pub fn lowerBound(self: *const Self, key: KeyLikeType) !?Iterator {
            const accessor = self.model.getAccessor();
            if (accessor.getRoot()) |root| {
                const search = try self.findLeafWith(key, root);
                if (search.leaf) |leaf_const| {
                    var leaf = leaf_const;
                    defer accessor.deinitLeaf(leaf);
                    return try Iterator.init(self.model, leaf.id(), .{ .on = search.position });
                }
            }
            return null;
        }

        pub fn dump(self: *Self) !void {
            const accessor = self.model.getAccessor();
            if (accessor.getRoot()) |root| {
                try self.dumpNode(root, 0);
            } else {
                std.debug.print("<Empty>\n", .{});
            }
        }

        fn dumpNode(self: *Self, node_id: NodedIdType, level: usize) !void {
            const accessor = self.model.getAccessor();

            // Print indentation
            for (0..level) |_| {
                std.debug.print("  ", .{});
            }

            if (try accessor.loadLeaf(node_id)) |const_leaf| {
                defer accessor.deinitLeaf(const_leaf);
                var leaf = const_leaf;
                // It's a leaf node
                std.debug.print("<id:{} p:{?} size:{}> * [", .{ leaf.id(), leaf.getParent(), leaf.size() });

                const n = leaf.size();
                for (0..n) |i| {
                    if (i > 0) {
                        std.debug.print(", ", .{});
                    }
                    const key = try leaf.getKey(i);
                    const value = try leaf.getValue(i);
                    std.debug.print("{}: '{s}'", .{ key, value });
                }
                std.debug.print("]\n", .{});
            } else if (try accessor.loadInode(node_id)) |inode| {
                accessor.deinitInode(inode);

                // It's an inode
                const n = inode.size();
                std.debug.print("<id:{} p:{?} size:{}> [", .{ inode.id(), inode.getParent(), n });

                for (0..n) |i| {
                    if (i > 0) {
                        std.debug.print(", ", .{});
                    }
                    const key = try inode.getKey(i);
                    std.debug.print("{}", .{key});
                }
                std.debug.print("] children: {}\n", .{n + 1});

                // Recursively dump children
                for (0..n + 1) |i| {
                    const child_id = try inode.getChild(i);
                    if (self.model.isValidId(child_id)) {
                        try self.dumpNode(child_id, level + 1);
                    }
                }
            } else {
                std.debug.print("<Invalid node: {}>\n", .{node_id});
            }
        }

        pub fn insert(self: *Self, key: KeyLikeType, value: ValueInType) !bool {
            const accessor = self.model.getAccessor();
            if (accessor.getRoot()) |root| {
                const search = try self.findLeafWith(key, root);
                defer accessor.deinitLeaf(search.leaf);
                if (!search.found) {
                    var leaf = search.leaf.?;
                    if (leaf.canInsertValue(search.position, key, value)) {
                        try leaf.insertValue(search.position, key, value);
                        //std.debug.print("Key {} inserted into leaf id: {}\n", .{ key, leaf.id() });
                    } else {
                        if (self.rebalance_policy == .neighbor_share) {
                            if (try self.tryLeafNeighborShare(&leaf, key, value, search.position)) {
                                return true;
                            }
                        }
                        try self.handleLeafOverflowDefault(&leaf, key, value, search.position);
                        return true;
                    }
                } else {
                    //std.debug.print("Key {} already exists in leaf id: {}\n", .{ key, search.leaf.?.id() });
                }
            } else {
                var leaf = try accessor.createLeaf();
                defer accessor.deinitLeaf(leaf);
                try leaf.insertValue(0, key, value);
                //std.debug.print("Created leaf node with id: {}\n", .{leafId.id()});
                accessor.setRoot(leaf.id());
                return true;
            }
            return false;
        }

        pub fn update(self: *Self, key: KeyLikeType, value: ValueInType) !bool {
            const accessor = self.model.getAccessor();
            if (accessor.getRoot()) |root| {
                const search = try self.findLeafWith(key, root);
                if (search.leaf) |leaf_const| {
                    var leaf = leaf_const;
                    defer accessor.deinitLeaf(leaf);
                    if (search.found) {
                        if (try leaf_const.canUpdateValue(search.position, key, value)) {
                            try leaf.updateValue(search.position, value);
                            return true;
                        } else {
                            // check if we can borrow from neighbors
                            // need to rebalance...
                            var right = try self.handleLeafOverflow(&leaf);
                            defer accessor.deinitLeaf(right);

                            if (search.position < leaf.size()) {
                                try leaf.updateValue(search.position, value);
                            } else {
                                try right.updateValue(search.position - leaf.size(), value);
                            }
                            return true;
                        }
                    }
                }
            }
            return false;
        }

        pub fn remove(self: *Self, key: KeyLikeType) !bool {
            const accessor = self.model.getAccessor();
            if (accessor.getRoot()) |root| {
                const search = try self.findLeafWith(key, root);
                if (search.leaf) |leaf_const| {
                    var leaf = leaf_const;
                    defer accessor.deinitLeaf(leaf);
                    if (search.found) {
                        try self.removeImpl(&leaf, search.position);
                        return true;
                    }
                }
            }
            return false;
        }

        // private methods

        fn removeImpl(self: *Self, leaf: *LeafType, pos: usize) !void {
            const accessor = self.model.getAccessor();
            const key = try accessor.borrowKeyfromLeaf(leaf, pos);
            defer accessor.deinitBorrowKey(key);

            try leaf.erase(pos);
            if (pos == 0 and leaf.size() > 0) {
                try self.fixParentIndex(leaf);
            }
            try self.leafHandleUnderflow(leaf, self.model.keyBorrowAsLike(&key));
            try self.fixEmptyRoot();
        }

        fn inodeHandleUnderflow(self: *Self, inode: *InodeType, key: KeyLikeType) !void {
            const accessor = self.model.getAccessor();
            const key_pos = try inode.keyPosition(key);
            if (key_pos > 0 and key_pos <= inode.size()) {
                const left_key_out = try inode.getKey(key_pos - 1);
                const left_key = self.model.keyOutAsLike(left_key_out);
                if (inode.keysEqual(left_key, key)) {
                    const child_id = try inode.getChild(key_pos);
                    const left_most_leaf = (try self.getLeftMostLeafId(child_id)).?;
                    const leaf_otp = accessor.loadLeaf(left_most_leaf);
                    if (try leaf_otp) |leaf| {
                        defer accessor.deinitLeaf(leaf);
                        const first_key = try leaf.getKey(0);
                        const key_like = self.model.keyOutAsLike(first_key);
                        try self.updateInodeKey(inode, key_pos - 1, key_like);
                    } else {
                        @breakpoint();
                        return error.InvalidNode;
                    }
                }
            }

            if (!try self.inodeTryMerge(inode) and inode.isUnderflowed()) {
                _ = try self.inodeTryBorrow(inode, 0);
            }

            if (try self.loadParentForInode(inode)) |parent_const| {
                var parent = parent_const;
                defer accessor.deinitInode(parent);
                try self.inodeHandleUnderflow(&parent, key);
                try self.fixEmptyRoot();
            }
        }

        fn leafHandleUnderflow(self: *Self, leaf: *LeafType, key: KeyLikeType) !void {
            const accessor = self.model.getAccessor();

            if (!try self.leafTryMerge(leaf) and leaf.isUnderflowed()) {
                _ = try self.leafTryBorrow(leaf, 0);
            }

            if (try self.loadParentForLeaf(leaf)) |parent_const| {
                var parent = parent_const;
                defer accessor.deinitInode(parent);
                try self.inodeHandleUnderflow(&parent, key);
                try self.fixParentIndex(leaf);
            }
        }

        fn fixEmptyRoot(self: *Self) !void {
            const accessor = self.model.getAccessor();
            if (!accessor.hasRoot()) {
                return;
            }
            const root_id = accessor.getRoot().?;
            if (try accessor.loadLeaf(root_id)) |root_leaf| {
                defer accessor.deinitLeaf(root_leaf);
                if (root_leaf.size() == 0) {
                    accessor.setRoot(null);
                    try accessor.destroy(root_id);
                }
            } else if (try accessor.loadInode(root_id)) |root_inode| {
                defer accessor.deinitInode(root_inode);
                if (root_inode.size() == 0) {
                    const child_id = try root_inode.getChild(0);
                    accessor.setRoot(child_id);
                    try accessor.destroy(root_id);
                }
            }
        }

        fn getLeftMostLeafId(self: *const Self, from: NodedIdType) !?NodedIdType {
            const accessor = self.model.getAccessor();
            if (!self.model.isValidId(from)) {
                return null;
            }
            var res = from;
            while (!try accessor.isLeafId(res)) {
                if (try accessor.loadInode(res)) |next| {
                    defer accessor.deinitInode(next);
                    res = try next.getChild(0);
                }
            }
            return res;
        }

        fn getRightMostLeafId(self: *const Self, from: NodedIdType) !?NodedIdType {
            const accessor = self.model.getAccessor();
            if (!self.model.isValidId(from)) {
                return null;
            }
            var res = from;
            while (!try accessor.isLeafId(res)) {
                if (try accessor.loadInode(res)) |next| {
                    defer accessor.deinitInode(next);
                    res = try next.getChild(next.size());
                }
            }
            return res;
        }

        // Borrowing from siblings
        fn tryLeafNeighborShare(self: *Self, leaf: *LeafType, key: KeyLikeType, value: ValueInType, position: usize) !bool {
            const accessor = self.model.getAccessor();
            const is_first = position == 0;
            const is_last = position == leaf.size();
            if (try self.leafGiveToLeft(leaf, if (is_first) 1 else 0)) {
                if (is_first) {
                    // do not use getPrev here, as we need onthe the same inode level
                    if (try self.findLeftSibling(leaf.getParent(), leaf.id())) |left_id| {
                        if (try accessor.loadLeaf(left_id)) |left_sibling_const| {
                            var left_sibling = left_sibling_const;
                            defer accessor.deinitLeaf(left_sibling);
                            try left_sibling.insertValue(left_sibling.size(), key, value);
                            //std.debug.print("Key {} inserted into leaf id: {} after borrowing from left sibling id: {}\n", .{ key, left_sibling.id(), left_id });
                            return true;
                        }
                    }
                } else {
                    const new_position = position - 1;
                    try leaf.insertValue(new_position, key, value);
                    if (new_position == 0) {
                        try self.fixParentIndex(leaf);
                    }
                    //std.debug.print("Key {} inserted into leaf id: {} after borrowing from left sibling\n", .{ key, leaf.id() });
                    return true;
                }
            } else if (try self.leafGiveToRight(leaf, if (is_last) 1 else 0)) {
                if (is_last) {
                    if (try self.findRightSibling(leaf.getParent(), leaf.id())) |right_id| {
                        if (try accessor.loadLeaf(right_id)) |right_sibling_const| {
                            defer accessor.deinitLeaf(right_sibling_const);

                            var right_sibling = right_sibling_const;
                            const right_pos = try right_sibling.keyPosition(key);
                            try right_sibling.insertValue(right_pos, key, value);
                            //std.debug.print("Key {} inserted into leaf id: {} after borrowing from right sibling id: {}\n", .{ key, right_sibling.id(), right_id });
                            return true;
                        }
                    }
                } else {
                    const new_position = position;
                    try leaf.insertValue(new_position, key, value);
                    if (new_position == 0) {
                        try self.fixParentIndex(leaf);
                    }
                    //std.debug.print("Key {} inserted into leaf id: {} after borrowing from right sibling\n", .{ key, leaf.id() });
                    return true;
                }
            }
            return false;
        }

        fn leafGiveToLeft(self: *Self, leaf: *LeafType, additional_elements: usize) !bool {
            const parent_id = leaf.getParent();
            if (!self.model.isValidId(parent_id)) {
                return false;
            }
            const accessor = self.model.getAccessor();
            if (try accessor.loadInode(parent_id)) |parent| {
                defer accessor.deinitInode(parent);

                if (try self.findLeftSibling(parent.id(), leaf.id())) |left_sibling_id| {
                    if (try accessor.loadLeaf(left_sibling_id)) |left_sibling_const| {
                        defer accessor.deinitLeaf(left_sibling_const);
                        var left_sibling = left_sibling_const;
                        if (left_sibling.size() < (left_sibling.capacity() - additional_elements)) {
                            return try self.leafBorrowFromRight(&left_sibling, leaf, additional_elements);
                        }
                    }
                }
            }
            return false;
        }

        fn leafGiveToRight(self: *Self, leaf: *LeafType, additional_elements: usize) !bool {
            const parent_id = leaf.getParent();
            if (!self.model.isValidId(parent_id)) {
                return false;
            }
            const accessor = self.model.getAccessor();
            if (try accessor.loadInode(parent_id)) |parent| {
                defer accessor.deinitInode(parent);

                if (try self.findRightSibling(parent.id(), leaf.id())) |right_sibling_id| {
                    if (try accessor.loadLeaf(right_sibling_id)) |right_sibling_const| {
                        defer accessor.deinitLeaf(right_sibling_const);
                        var right_sibling = right_sibling_const;
                        if (right_sibling.size() < (right_sibling.capacity() - additional_elements)) {
                            //std.debug.print("right_sibling id: {}\n", .{right_sibling.id()});
                            return try self.leafBorrowFromLeft(&right_sibling, leaf, additional_elements);
                        }
                    }
                }
            }
            return false;
        }

        fn inodeGiveToLeft(self: *Self, inode: *InodeType, additional_elements: usize) !bool {
            const parent_id = inode.getParent();
            if (!self.model.isValidId(parent_id)) {
                return false;
            }
            const accessor = self.model.getAccessor();
            if (try accessor.loadInode(parent_id)) |parent| {
                defer accessor.deinitInode(parent);
                if (try self.findLeftSibling(parent.id(), inode.id())) |left_sibling_id| {
                    if (try accessor.loadInode(left_sibling_id)) |left_sibling_const| {
                        defer accessor.deinitInode(left_sibling_const);
                        var left_sibling = left_sibling_const;
                        if (left_sibling.size() < (left_sibling.capacity() - additional_elements)) {
                            return try self.inodeBorrowFromRight(&left_sibling, inode, additional_elements);
                        }
                    }
                }
            }
            return false;
        }

        fn inodeGiveToRight(self: *Self, inode: *InodeType, additional_elements: usize) !bool {
            const parent_id = inode.getParent();
            if (!self.model.isValidId(parent_id)) {
                return false;
            }
            const accessor = self.model.getAccessor();
            if (try accessor.loadInode(parent_id)) |parent| {
                defer accessor.deinitInode(parent);
                if (try self.findRightSibling(parent.id(), inode.id())) |right_sibling_id| {
                    if (try accessor.loadInode(right_sibling_id)) |right_sibling_const| {
                        defer accessor.deinitInode(right_sibling_const);
                        var right_sibling = right_sibling_const;
                        if (right_sibling.size() < (right_sibling.capacity() - additional_elements)) {
                            return try self.inodeBorrowFromLeft(&right_sibling, inode, additional_elements);
                        }
                    }
                }
            }
            return false;
        }

        fn leafBorrowFromLeft(self: *Self, leaf: *LeafType, left: *LeafType, additional_elements: usize) !bool {
            const max_elements = leaf.capacity();
            const min_elements = (max_elements + 1) / 2 - 1;
            const accessor = self.model.getAccessor();
            if (left.size() > (min_elements + additional_elements)) {
                const key_to_check = try left.getKey(left.size() - 1);
                const key_like = self.model.keyOutAsLike(key_to_check);
                if (try accessor.loadInode(leaf.getParent())) |parent_const| {
                    defer accessor.deinitInode(parent_const);
                    var parent = parent_const;
                    const pos_in_parent = try self.findChidIndexInParentId(parent.id(), leaf.id());
                    if (parent.canUpdateKey(pos_in_parent, key_like)) {
                        const out_key = try left.getKey(left.size() - 1);
                        const out_value = try left.getValue(left.size() - 1);

                        const key = self.model.keyOutAsLike(out_key);
                        const value = self.model.valueOutAsIn(out_value);

                        try leaf.insertValue(0, key, value);
                        try left.erase(left.size() - 1);
                        try parent.updateKey(pos_in_parent - 1, self.model.keyOutAsLike(try leaf.getKey(0)));
                        return true;
                    }
                }
            }
            return false;
        }

        fn leafBorrowFromRight(self: *Self, leaf: *LeafType, right: *LeafType, additional_elements: usize) !bool {
            const max_elements = leaf.capacity();
            const min_elements = (max_elements + 1) / 2 - 1;
            const accessor = self.model.getAccessor();
            if (right.size() > (min_elements + additional_elements)) {
                const key_to_check = try right.getKey(1);
                const key_like = self.model.keyOutAsLike(key_to_check);
                if (try accessor.loadInode(leaf.getParent())) |parent_const| {
                    defer accessor.deinitInode(parent_const);

                    var parent = parent_const;
                    const pos_in_parent = try self.findChidIndexInParentId(parent.id(), leaf.id());
                    if (parent.canUpdateKey(pos_in_parent, key_like)) {
                        const out_key = try right.getKey(0);
                        const out_value = try right.getValue(0);

                        const key = self.model.keyOutAsLike(out_key);
                        const value = self.model.valueOutAsIn(out_value);

                        try leaf.insertValue(leaf.size(), key, value);
                        try right.erase(0);
                        try parent.updateKey(pos_in_parent, self.model.keyOutAsLike(try right.getKey(0)));
                        return true;
                    }
                }
            }
            return false;
        }

        fn leafTryBorrowFromLeft(self: *Self, leaf: *LeafType, additional_elements: usize) !bool {
            const parent_id = leaf.getParent();
            if (!self.model.isValidId(parent_id)) {
                return false;
            }
            const accessor = self.model.getAccessor();
            if (try accessor.loadInode(parent_id)) |parent| {
                defer accessor.deinitInode(parent);
                if (try self.findLeftSibling(parent.id(), leaf.id())) |left_sibling_id| {
                    if (try accessor.loadLeaf(left_sibling_id)) |left_sibling_const| {
                        defer accessor.deinitLeaf(left_sibling_const);
                        var left_sibling = left_sibling_const;
                        return try self.leafBorrowFromLeft(leaf, &left_sibling, additional_elements);
                    }
                }
            }
            return false;
        }

        fn leafTryBorrowFromRight(self: *Self, leaf: *LeafType, additional_elements: usize) !bool {
            const parent_id = leaf.getParent();
            if (!self.model.isValidId(parent_id)) {
                return false;
            }
            const accessor = self.model.getAccessor();
            if (try accessor.loadInode(parent_id)) |parent| {
                defer accessor.deinitInode(parent);
                if (try self.findRightSibling(parent.id(), leaf.id())) |right_sibling_id| {
                    if (try accessor.loadLeaf(right_sibling_id)) |right_sibling_const| {
                        defer accessor.deinitLeaf(right_sibling_const);
                        var right_sibling = right_sibling_const;
                        return try self.leafBorrowFromRight(leaf, &right_sibling, additional_elements);
                    }
                }
            }
            return false;
        }

        fn leafTryBorrow(self: *Self, leaf: *LeafType, additional_elements: usize) !bool {
            if (try self.leafTryBorrowFromLeft(leaf, additional_elements)) {
                return true;
            }
            if (try self.leafTryBorrowFromRight(leaf, additional_elements)) {
                return true;
            }
            return false;
        }

        fn inodeBorrowFromLeft(self: *Self, inode: *InodeType, left: *InodeType, additional_elements: usize) !bool {
            const max_elements = inode.capacity();
            const min_elements = (max_elements + 1) / 2 - 1;
            const accessor = self.model.getAccessor();
            if (left.size() > min_elements + additional_elements) {
                if (try accessor.loadInode(inode.getParent())) |parent_const| {
                    defer accessor.deinitInode(parent_const);
                    var parent = parent_const;
                    const pos_in_parent = try self.findChidIndexInParentId(parent.id(), inode.id());

                    const borrow_parent_key = try accessor.borrowKeyfromInode(&parent, pos_in_parent - 1);
                    defer accessor.deinitBorrowKey(borrow_parent_key);

                    const borrow_key = try accessor.borrowKeyfromInode(left, left.size() - 1);
                    defer accessor.deinitBorrowKey(borrow_key);

                    const parent_key = self.model.keyBorrowAsLike(&borrow_parent_key);
                    const key = self.model.keyBorrowAsLike(&borrow_key);
                    const child_id = try left.getChild(left.size()); // right most child

                    try self.setChildParent(child_id, inode.id());
                    try inode.insertChild(0, parent_key, child_id);

                    // TODO: check if we can use getKey here instead
                    try self.updateInodeKey(&parent, pos_in_parent - 1, key);

                    try self.swapChildren(left, left.size(), left.size() - 1);
                    try left.erase(left.size() - 1);

                    return true;
                }
            }
            return false;
        }

        fn inodeBorrowFromRight(self: *Self, inode: *InodeType, right: *InodeType, additional_elements: usize) !bool {
            const max_elements = inode.capacity();
            const min_elements = (max_elements + 1) / 2 - 1;
            const accessor = self.model.getAccessor();
            if (right.size() > min_elements + additional_elements) {
                if (try accessor.loadInode(inode.getParent())) |parent_const| {
                    defer accessor.deinitInode(parent_const);

                    var parent = parent_const;
                    const pos_in_parent = try self.findChidIndexInParentId(parent.id(), inode.id());

                    const borrow_parent_key = try accessor.borrowKeyfromInode(&parent, pos_in_parent);
                    defer accessor.deinitBorrowKey(borrow_parent_key);

                    const borrow_key = try accessor.borrowKeyfromInode(right, 0);
                    defer accessor.deinitBorrowKey(borrow_key);

                    const parent_key = self.model.keyBorrowAsLike(&borrow_parent_key);
                    const key = self.model.keyBorrowAsLike(&borrow_key);
                    const child_id = try right.getChild(0);

                    // TODO: check if we can use getKey here instead
                    try self.setChildParent(child_id, inode.id());
                    try self.updateInodeKey(&parent, pos_in_parent, key);

                    const last_child = try inode.getChild(inode.size());
                    try inode.insertChild(inode.size(), parent_key, last_child);
                    try inode.updateChild(inode.size(), child_id);

                    try right.erase(0);

                    return true;
                }
            }
            return false;
        }

        fn inodeTryBorrowLeft(self: *Self, inode: *InodeType, additional_elements: usize) !bool {
            const parent_id = inode.getParent();
            if (!self.model.isValidId(parent_id)) {
                return false;
            }
            const accessor = self.model.getAccessor();
            if (try accessor.loadInode(parent_id)) |parent| {
                defer accessor.deinitInode(parent);
                if (try self.findLeftSibling(parent.id(), inode.id())) |left_sibling_id| {
                    if (try accessor.loadInode(left_sibling_id)) |left_sibling_const| {
                        defer accessor.deinitInode(left_sibling_const);
                        var left_sibling = left_sibling_const;
                        return try self.inodeBorrowFromLeft(inode, &left_sibling, additional_elements);
                    }
                }
            }
            return false;
        }

        fn inodeTryBorrowRight(self: *Self, inode: *InodeType, additional_elements: usize) !bool {
            const parent_id = inode.getParent();
            if (!self.model.isValidId(parent_id)) {
                return false;
            }
            const accessor = self.model.getAccessor();
            if (try accessor.loadInode(parent_id)) |parent| {
                defer accessor.deinitInode(parent);
                if (try self.findRightSibling(parent.id(), inode.id())) |right_sibling_id| {
                    if (try accessor.loadInode(right_sibling_id)) |right_sibling_const| {
                        defer accessor.deinitInode(right_sibling_const);
                        var right_sibling = right_sibling_const;
                        return try self.inodeBorrowFromRight(inode, &right_sibling, additional_elements);
                    }
                }
            }
            return false;
        }

        fn inodeTryBorrow(self: *Self, inode: *InodeType, additional_elements: usize) !bool {
            if (try self.inodeTryBorrowLeft(inode, additional_elements)) {
                return true;
            }
            if (try self.inodeTryBorrowRight(inode, additional_elements)) {
                return true;
            }
            return false;
        }

        // Merging nodes
        fn leafMergeWithRight(self: *Self, leaf: *LeafType) !bool {
            const accessor = self.model.getAccessor();
            if (try accessor.loadInode(leaf.getParent())) |parent_const| {
                defer accessor.deinitInode(parent_const);

                if (try self.findRightSibling(parent_const.id(), leaf.id())) |right_id| {
                    if (try accessor.loadLeaf(right_id)) |right_sibling_const| {
                        defer accessor.deinitLeaf(right_sibling_const);

                        var right_sibling = right_sibling_const;
                        if (accessor.canMergeLeafs(leaf, &right_sibling)) {
                            for (0..right_sibling.size()) |i| {
                                const out_key = try right_sibling.getKey(i);
                                const out_value = try right_sibling.getValue(i);

                                const key = self.model.keyOutAsLike(out_key);
                                const value = self.model.valueOutAsIn(out_value);

                                try leaf.insertValue(leaf.size(), key, value);
                            }
                            leaf.setNext(right_sibling.getNext());
                            if (right_sibling.getNext()) |next_id| {
                                if (try accessor.loadLeaf(next_id)) |next_leaf_const| {
                                    defer accessor.deinitLeaf(next_leaf_const);
                                    var next_leaf = next_leaf_const;
                                    next_leaf.setPrev(leaf.id());
                                }
                            }
                            const right_pos = try self.findChidIndexInParentId(parent_const.id(), right_id);
                            var parent = parent_const;
                            try self.swapChildren(&parent, right_pos - 1, right_pos);
                            try accessor.destroy(right_id);
                            try parent.erase(right_pos - 1);
                            return true;
                        }
                    }
                }
            }
            return false;
        }

        fn leafMergeWithLeft(self: *Self, leaf: *LeafType) !bool {
            const accessor = self.model.getAccessor();
            if (try self.findLeftSibling(leaf.getParent(), leaf.id())) |left_id| {
                if (try accessor.loadLeaf(left_id)) |left_sibling_const| {
                    var left_sibling = left_sibling_const;
                    defer accessor.deinitLeaf(left_sibling);
                    if (try self.leafMergeWithRight(&left_sibling)) {
                        accessor.deinitLeaf(leaf.*);
                        leaf.* = left_sibling.move();
                        return true;
                    }
                }
            }
            return false;
        }

        fn leafTryMerge(self: *Self, leaf: *LeafType) !bool {
            if (leaf.size() == 0) {
                //@breakpoint();
            }

            if (try self.leafMergeWithRight(leaf)) {
                //std.debug.print("Merged leaf id: {} with right sibling\n", .{leaf.id()});
                return true;
            }
            if (try self.leafMergeWithLeft(leaf)) {
                //std.debug.print("Merged leaf id: {} with left sibling\n", .{leaf.id()});
                //return try self.model.getAccessor().loadLeaf(merged.id());
                return true;
            }
            return false;
        }

        fn inodeMergeWithRight(self: *Self, inode: *InodeType) !bool {
            const accessor = self.model.getAccessor();
            if (try self.findRightSibling(inode.getParent(), inode.id())) |right_id| {
                if (try accessor.loadInode(right_id)) |right_sibling_const| {
                    defer accessor.deinitInode(right_sibling_const);
                    var right_sibling = right_sibling_const;
                    if (accessor.canMergeInodes(inode, &right_sibling)) {
                        if (try accessor.loadInode(inode.getParent())) |parent_const| {
                            defer accessor.deinitInode(parent_const);
                            var parent = parent_const;

                            const right_pos = try self.findChidIndexInParentId(parent.id(), right_id);
                            const borrow_separator_key = try parent.getKey(right_pos - 1);
                            const separator_key = self.model.keyOutAsLike(borrow_separator_key);
                            const last_node_child = try inode.getChild(inode.size());

                            try inode.insertChild(inode.size(), separator_key, last_node_child);
                            for (0..right_sibling.size()) |i| {
                                const out_key = try right_sibling.getKey(i);
                                const child_id = try right_sibling.getChild(i);
                                const key = self.model.keyOutAsLike(out_key);

                                try inode.insertChild(inode.size(), key, child_id);
                                try self.setChildParent(child_id, inode.id());
                            }

                            const right_most_child = try right_sibling.getChild(right_sibling.size());
                            try inode.updateChild(inode.size(), right_most_child);
                            try self.setChildParent(right_most_child, inode.id());
                            try self.swapChildren(&parent, right_pos - 1, right_pos);

                            try accessor.destroy(right_id);
                            try parent.erase(right_pos - 1);
                            return true;
                        }
                    }
                }
            }
            return false;
        }

        fn inodeMergeWithLeft(self: *Self, inode: *InodeType) !bool {
            const accessor = self.model.getAccessor();
            if (try self.findLeftSibling(inode.getParent(), inode.id())) |left_id| {
                if (try accessor.loadInode(left_id)) |left_sibling_const| {
                    var left_sibling = left_sibling_const;
                    defer accessor.deinitInode(left_sibling);
                    if (try self.inodeMergeWithRight(&left_sibling)) {
                        accessor.deinitInode(inode.*);
                        inode.* = left_sibling.move();
                        return true;
                    }
                }
            }
            return false;
        }

        fn inodeTryMerge(self: *Self, inode: *InodeType) !bool {
            if (try self.inodeMergeWithRight(inode)) {
                //: {} with right sibling\n", .{inode.id()});
                return true;
            }
            if (try self.inodeMergeWithLeft(inode)) {
                //std.debug.print("Merged inode id: {} with left sibling\n", .{inode.id()});
                return true;
            }
            return false;
        }

        const SearchResult = struct {
            leaf: ?LeafType, // node with the potential to insert
            position: usize, // position to insert
            found: bool, // if the key was actually found
        };

        fn findLeafWith(self: *const Self, key: KeyLikeType, id: NodedIdType) !SearchResult {
            const accessor = self.model.getAccessor();
            const not_found = SearchResult{
                .leaf = null,
                .position = 0,
                .found = false,
            };
            var current: NodedIdType = id;
            while (true) {
                if (try accessor.loadLeaf(current)) |leaf_const| {
                    var leaf = leaf_const;
                    defer accessor.deinitLeaf(leaf);
                    const keyPos = leaf.keyPosition(key) catch return not_found;
                    if (keyPos < leaf.size()) {
                        const existingKey = try leaf.getKey(keyPos);
                        const eq = leaf.keysEqual(self.model.keyOutAsLike(existingKey), key);
                        return .{ .leaf = leaf.move(), .position = keyPos, .found = eq };
                    }
                    return .{ .leaf = leaf.move(), .position = keyPos, .found = false };
                } else if (try accessor.loadInode(current)) |inode| {
                    defer accessor.deinitInode(inode);
                    const keyPos = inode.keyPosition(key) catch return not_found;
                    current = try inode.getChild(keyPos);
                } else {
                    return error.InvalidNode;
                }
            }
        }

        fn handleLeafOverflowDefault(self: *Self, leaf: *LeafType, key: KeyLikeType, value: ValueInType, pos: usize) !void {
            var res = try self.handleLeafOverflow(leaf);
            defer self.model.getAccessor().deinitLeaf(res);
            if (leaf.size() < pos) {
                const insert_pos = pos - leaf.size();
                try res.insertValue(insert_pos, key, value);
                if (insert_pos == 0) {
                    try self.fixParentIndex(&res);
                }
            } else {
                try leaf.insertValue(pos, key, value);
                if (pos == 0) {
                    try self.fixParentIndex(leaf);
                }
            }
        }

        fn handleLeafOverflow(self: *Self, leaf: *LeafType) !LeafType {
            const leaf_if = leaf.id();
            const accessor = self.model.getAccessor();
            var new_root: ?InodeType = null;
            defer accessor.deinitInode(new_root);

            if (!self.model.isValidId(leaf.getParent())) {
                new_root = try accessor.createInode();
            }
            var split_result = try self.splitLeaf(leaf);
            var right_leaf = split_result.right.move();
            defer accessor.deinitLeaf(right_leaf);

            if (new_root) |nr_const| { // leaf is root
                var nr = nr_const;
                right_leaf.setParent(nr.id());
                leaf.setParent(nr.id());

                const first_key = try right_leaf.getKey(0);
                const first_key_like = self.model.keyOutAsLike(first_key);

                try nr.insertChild(0, first_key_like, leaf_if);
                try nr.updateChild(1, right_leaf.id());
                accessor.setRoot(nr.id());
            } else {
                var parent: InodeType = undefined;
                defer accessor.deinitInode(parent);

                const parent_id = leaf.getParent();
                var pos = try self.findChidIndexInParentId(parent_id, leaf.id());
                if (try accessor.loadInode(parent_id)) |p| {
                    parent = p;
                }
                var pos_child = try parent.getChild(pos);
                const key_like = split_result.middle_key;

                try self.handleInodeOverflowDefault(&parent, key_like, pos_child, pos);

                const new_parent_id = leaf.getParent();
                if (parent_id != new_parent_id) {
                    if (try accessor.loadInode(new_parent_id)) |p| {
                        accessor.deinitInode(parent);
                        parent = p;
                    }
                }

                pos = try self.findChidIndexInParentId(new_parent_id, leaf.id());

                right_leaf.setParent(parent.id());
                const first_key = try right_leaf.getKey(0);
                const first_key_like = self.model.keyOutAsLike(first_key);
                pos_child = try parent.getChild(pos);

                // TODO: investigate why this happens
                if (parent.canInsertChild(pos, first_key_like, pos_child)) {
                    // all good
                } else {
                    std.debug.print("Parent inode id: {} cannot insert child at pos: {} with key: {}\n", .{ parent.id(), pos, first_key });
                    @breakpoint();
                }

                try parent.insertChild(pos, first_key_like, pos_child);
                try parent.updateChild(pos + 1, right_leaf.id());
            }
            return right_leaf.move();
        }

        // TODO: refactor to avoid code duplication with handleInodeOverflow and error list is too long
        fn handleInodeOverflowDefault(self: *Self, inode: *InodeType, key: KeyLikeType, child_opt: ?NodedIdType, pos: usize) error{ Full, OutOfMemory, InvalidNode, ChildNotFoundInParent, NoParent, OutOfBounds }!void {
            if (child_opt) |child| {
                if (!inode.canInsertChild(pos, key, child)) {
                    if (self.rebalance_policy == .neighbor_share) {
                        if (try self.inodeGiveToLeft(inode, 1)) {
                            return;
                        }
                        if (try self.inodeGiveToRight(inode, 1)) {
                            return;
                        }
                    }
                    self.model.getAccessor().deinitInode(try self.handleInodeOverflow(inode));
                }
            }
        }

        // TODO: refactor to avoid code duplication with handleLeafOverflow
        fn handleInodeOverflow(self: *Self, inode: *InodeType) error{ OutOfMemory, InvalidNode, ChildNotFoundInParent, NoParent, OutOfBounds, Full }!InodeType {
            const accessor = self.model.getAccessor();
            var new_root: ?InodeType = null;
            defer accessor.deinitInode(new_root);

            if (!self.model.isValidId(inode.getParent())) {
                new_root = try accessor.createInode();
            }
            const res = try self.splitInode(inode);
            var right_inode = res.right;
            defer {
                accessor.deinitInode(right_inode);
                accessor.deinitBorrowKey(res.middle_key);
            }

            if (new_root) |nr_const| {
                var nr = nr_const;
                inode.setParent(nr.id());
                try nr.insertChild(0, self.model.keyBorrowAsLike(&res.middle_key), inode.id());
                try nr.updateChild(1, right_inode.id());
                inode.setParent(nr.id());
                right_inode.setParent(nr.id());
                accessor.setRoot(nr.id());
            } else {
                var parent: InodeType = undefined;
                defer accessor.deinitInode(parent);
                var parent_id = inode.getParent();
                var pos = try self.findChidIndexInParentId(parent_id, inode.id());
                if (try accessor.loadInode(parent_id)) |p| {
                    parent = p;
                }
                var pos_child = try parent.getChild(pos);
                const key_like = self.model.keyBorrowAsLike(&res.middle_key);

                try self.handleInodeOverflowDefault(&parent, key_like, pos_child, pos);

                parent_id = inode.getParent();
                pos = try self.findChidIndexInParentId(parent_id, inode.id());
                if (try accessor.loadInode(parent_id)) |p| {
                    accessor.deinitInode(parent);
                    parent = p;
                }
                pos_child = try parent.getChild(pos);
                right_inode.setParent(parent.id());
                try parent.insertChild(pos, key_like, pos_child);
                try parent.updateChild(pos + 1, right_inode.id());
            }
            return right_inode.move();
        }

        fn findChidIndexInParentInode(self: *Self, child: *const InodeType) !usize {
            const parent_id = child.getParent();
            return self.findChidIndexInParentId(parent_id, child.id());
        }

        fn findChidIndexInParentLeaf(self: *Self, child: *const LeafType) !usize {
            const parent_id = child.getParent();
            return self.findChidIndexInParentId(parent_id, child.id());
        }

        fn findChidIndexInParentId(self: *Self, parent_id: ?NodedIdType, child: NodedIdType) !usize {
            const accessor = self.model.getAccessor();
            if (self.model.isValidId(parent_id)) {
                if (try accessor.loadInode(parent_id)) |parent| {
                    defer accessor.deinitInode(parent);

                    const n = parent.size();
                    for (0..n + 1) |i| { // + right most child
                        const cid = try parent.getChild(i);
                        if (cid == child) {
                            return i;
                        }
                    }
                    return error.ChildNotFoundInParent;
                } else {
                    return error.InvalidNode;
                }
            } else {
                return error.NoParent;
            }
        }

        pub fn fixParentIndex(self: *Self, child: *const LeafType) !void {
            const accessor = self.model.getAccessor();
            const parent_id = child.getParent();
            if (self.model.isValidId(parent_id)) {
                if (try accessor.loadInode(parent_id)) |parent_const| {
                    defer accessor.deinitInode(parent_const);
                    var parent = parent_const;
                    const pos = try self.findChidIndexInParentLeaf(child);
                    // TODO: check if update is available
                    if (pos > 0) {
                        try updateParentInodeKey(self, &parent, pos - 1, child);
                    }
                }
            }
        }

        pub fn updateParentInodeKey(self: *Self, parent: *InodeType, pos: usize, child: *const LeafType) !void {
            if (child.size() == 0) {
                return;
            }
            const first_key = try child.getKey(0);
            const first_key_like = self.model.keyOutAsLike(first_key);
            if (!parent.canUpdateKey(pos, first_key_like)) {
                var right = try self.handleInodeOverflow(parent);
                const key_like = self.model.keyOutAsLike(first_key);
                if (pos < parent.size()) {
                    try parent.updateKey(pos, key_like);
                } else if (pos > parent.size()) {
                    const new_pos = pos - parent.size() - 1;
                    try right.updateKey(new_pos, key_like);
                }
            } else {
                try parent.updateKey(pos, first_key_like);
            }
        }

        pub fn updateInodeKey(self: *Self, inode: *InodeType, pos: usize, key: KeyLikeType) !void {
            if (!inode.canUpdateKey(pos, key)) {
                var right = try self.handleInodeOverflow(inode);
                if (pos < inode.size()) {
                    try inode.updateKey(pos, key);
                } else if (pos == inode.size()) {
                    if (try self.model.getAccessor().loadInode(inode.getParent())) |parent_const| {
                        var parent = parent_const;
                        const parent_pos = try self.findChidIndexInParentId(parent.id(), inode.id());
                        try self.updateInodeKey(&parent, parent_pos, key);
                    }
                } else if (pos > inode.size()) {
                    const new_pos = pos - inode.size() - 1;
                    try right.updateKey(new_pos, key);
                }
            } else {
                try inode.updateKey(pos, key);
            }
        }

        const SplitLeafResult = struct {
            right: LeafType, // todo: do i need here ?
            middle_key: KeyLikeType,
        };

        fn splitLeaf(self: *Self, leaf: *LeafType) !SplitLeafResult {
            const maximum = leaf.size();
            const mid = maximum / 2;
            const mode_id = leaf.id();
            const accessor = self.model.getAccessor();

            var right = try accessor.createLeaf();
            defer self.model.getAccessor().deinitLeaf(right);

            for (mid..maximum) |i| {
                const out_key = try leaf.getKey(i);
                const out_value = try leaf.getValue(i);

                const key_like = self.model.keyOutAsLike(out_key);
                const value_in = self.model.valueOutAsIn(out_value);

                try right.insertValue(right.size(), key_like, value_in);
            }
            right.setParent(leaf.getParent());
            right.setPrev(mode_id);
            if (leaf.getNext()) |ln| {
                right.setNext(ln);
            }
            leaf.setNext(right.id());
            {
                if (right.getNext()) |next_id| {
                    if (try accessor.loadLeaf(next_id)) |next_leaf_const| {
                        defer accessor.deinitLeaf(next_leaf_const);
                        var next_leaf = next_leaf_const;
                        next_leaf.setPrev(right.id());
                    }
                }
            }

            for (mid..maximum) |_| {
                try leaf.erase(mid);
            }

            const mid_key = try right.getKey(0);
            return SplitLeafResult{
                .right = right.move(),
                .middle_key = self.model.keyOutAsLike(mid_key),
            };
        }

        const SplitInodeResult = struct {
            right: InodeType,
            middle_key: KeyBorrowType,
        };

        fn splitInode(self: *Self, inode: *InodeType) !SplitInodeResult {
            const accessor = self.model.getAccessor();
            const maximum = inode.size();
            const mid = maximum / 2;
            const reduce_size = (maximum - mid);

            var right = try accessor.createInode();
            defer accessor.deinitInode(right);

            const middle_key = try accessor.borrowKeyfromInode(inode, mid);

            right.setParent(inode.getParent());
            for (mid + 1..maximum) |i| {
                const out_key = try inode.getKey(i);
                const child_id = try inode.getChild(i);
                const key_like = self.model.keyOutAsLike(out_key);
                try self.setChildParent(child_id, right.id());
                try right.insertChild(right.size(), key_like, child_id);
            }
            const last_child_id = try inode.getChild(maximum);
            try self.setChildParent(last_child_id, right.id());
            try right.updateChild(right.size(), last_child_id);
            for (0..reduce_size) |_| {
                const last_child_pos = inode.size() - 1;
                try self.swapChildren(inode, last_child_pos, last_child_pos + 1);
                try inode.erase(last_child_pos);
            }

            return SplitInodeResult{
                .right = right.move(),
                .middle_key = middle_key,
            };
        }

        fn swapChildren(_: *const Self, inode: *InodeType, a: usize, b: usize) !void {
            const child_a = try inode.getChild(a);
            const child_b = try inode.getChild(b);
            try inode.updateChild(a, child_b);
            try inode.updateChild(b, child_a);
        }

        fn setChildParent(self: *Self, child_id: NodedIdType, parent_id: NodedIdType) !void {
            const accessor = self.model.getAccessor();
            if (try accessor.loadInode(child_id)) |child_inode_const| {
                defer accessor.deinitInode(child_inode_const);
                var child_inode = child_inode_const;
                child_inode.setParent(parent_id);
            } else if (try accessor.loadLeaf(child_id)) |child_leaf_const| {
                defer accessor.deinitLeaf(child_leaf_const);
                var child_leaf = child_leaf_const;
                child_leaf.setParent(parent_id);
            } else {
                return error.InvalidNode;
            }
        }

        // Sibling finders. It tryes to find siblings only on the same level and the same inode (no climbing up or down the tree)
        fn findLeftSibling(self: *Self, parent_id_opt: ?NodedIdType, child_id_opt: ?NodedIdType) !?NodedIdType {
            const accessor = self.model.getAccessor();
            var parent_id: NodedIdType = undefined;
            var child_id: NodedIdType = undefined;
            if (parent_id_opt) |val| {
                parent_id = val;
            } else {
                return null;
            }
            if (child_id_opt) |val| {
                child_id = val;
            } else {
                return null;
            }

            if (try accessor.loadInode(parent_id)) |parent| {
                defer accessor.deinitInode(parent);
                const pos = try self.findChidIndexInParentId(parent.id(), child_id);
                if (pos > 0) {
                    return try parent.getChild(pos - 1);
                }
            }
            return null;
        }

        fn findRightSibling(self: *Self, parent_id: ?NodedIdType, child_id: NodedIdType) !?NodedIdType {
            const accessor = self.model.getAccessor();
            if (try accessor.loadInode(parent_id)) |parent| {
                defer accessor.deinitInode(parent);

                const pos = try self.findChidIndexInParentId(parent.id(), child_id);
                if (pos < parent.size()) {
                    return try parent.getChild(pos + 1);
                }
            }
            return null;
        }

        fn loadParentForLeaf(self: *Self, leaf: *const LeafType) !?InodeType {
            const parent_id = leaf.getParent();
            if (self.model.isValidId(parent_id)) {
                const accessor = self.model.getAccessor();
                if (try accessor.loadInode(parent_id)) |parent| {
                    return parent;
                }
            }
            return null;
        }

        fn loadParentForInode(self: *Self, inode: *const InodeType) !?InodeType {
            const parent_id = inode.getParent();
            if (self.model.isValidId(parent_id)) {
                const accessor = self.model.getAccessor();
                if (try accessor.loadInode(parent_id)) |parent| {
                    return parent;
                }
            }
            return null;
        }
    };
}
