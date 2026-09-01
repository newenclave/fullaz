const std = @import("std");
const core = @import("../core/core.zig");
const errors = core.errors;

const interfaces = @import("models/interfaces.zig");

pub const RebalancePolicy = enum {
    force_split,
    neighbor_share,
};

pub fn Bpt(comptime ModelT: type) type {
    comptime {
        interfaces.assertModel(ModelT);
    }

    return struct {
        model: *ModelT,
        rebalance_policy: RebalancePolicy = .neighbor_share,

        pub const Error = ModelT.Error || errors.BptError;

        const Self = @This();
        // model types
        pub const KeyLikeType = ModelT.KeyLikeType;
        pub const KeyOutType = ModelT.KeyOutType;
        pub const KeyBorrowType = ModelT.KeyBorrowType;

        pub const ValueInType = ModelT.ValueInType;
        pub const ValueOutType = ModelT.ValueOutType;
        pub const NodeIdType = ModelT.NodeIdType;
        pub const PageId = NodeIdType;

        pub const InodeType = ModelT.InodeType;
        pub const LeafType = ModelT.LeafType;

        /// An owned mutable lease for one value with a stable stored length.
        /// The tree and its model must outlive the editor.
        pub const ValueEditor = struct {
            const EditorSelf = @This();

            editor: ModelT.ValueEditorType,

            pub fn valueMut(self: *EditorSelf) ModelT.ValueEditorType.Error![]u8 {
                return self.editor.valueMut();
            }

            pub fn finish(self: *EditorSelf) ModelT.ValueEditorType.Error!void {
                return self.editor.finish();
            }

            pub fn deinit(self: *EditorSelf) void {
                self.editor.deinit();
            }
        };

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
                node_id: NodeIdType,
                pos: usize,
            };

            pub fn init(model: ?*ModelT, node_id: NodeIdType, cursor: Cursor) Error!ItrSelf {
                var res = ItrSelf{
                    .model = model,
                    .node = null,
                    .cursor = cursor,
                    .structural_generation = 0,
                };
                if (model) |mod| {
                    var m = mod;
                    res.structural_generation = m.structuralMutationCoordinator().generation();
                    const accessor = m.accessor();
                    if (try accessor.loadLeaf(node_id)) |node| {
                        res.node = node;
                    }
                }
                return res;
            }

            pub fn get(self: *const ItrSelf) Error!?Result {
                if (self.node) |node| {
                    return switch (self.cursor) {
                        .on => |i| blk: {
                            if (i >= try node.size()) {
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

            pub fn next(self: *ItrSelf) Error!?Result {
                if (self.node) |node| {
                    switch (self.cursor) {
                        .before_first => {
                            if (try node.size() > 0) {
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
                            if (next_idx >= try node.size()) {
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

            pub fn prev(self: *ItrSelf) Error!?Result {
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
                            if (try node.size() > 0) {
                                self.cursor = .{ .on = try node.size() - 1 };
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
                    model.accessor().deinitLeaf(self.node);
                }
            }

            /// Opens an editor for this iterator's exact current entry.
            pub fn editValue(self: *ItrSelf) Error!?ValueEditor {
                const model = self.model orelse return null;
                try model.structuralMutationCoordinator().checkGeneration(self.structural_generation);
                var node = self.node orelse return null;
                const position = switch (self.cursor) {
                    .on => |value| value,
                    else => return null,
                };
                if (position >= try node.size()) {
                    return null;
                }
                return .{ .editor = try model.accessor().openValueEditor(&node, position) };
            }

            fn moveNext(self: *ItrSelf, next_id: ?NodeIdType) Error!bool {
                if (self.model) |cmodel| {
                    var model = cmodel;
                    var pid_opt = next_id;
                    const accessor = model.accessor();
                    while (pid_opt) |pid| {
                        if (try accessor.loadLeaf(pid)) |next_node| {
                            if (try next_node.size() > 0) {
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

            fn movePrev(self: *ItrSelf, prev_id: ?NodeIdType) Error!bool {
                if (self.model) |cmodel| {
                    var model = cmodel;
                    var pid_opt = prev_id;
                    const accessor = model.accessor();
                    while (pid_opt) |pid| {
                        if (try accessor.loadLeaf(pid)) |prev_node| {
                            if (try prev_node.size() > 0) {
                                accessor.deinitLeaf(self.node);
                                self.node = prev_node;
                                self.cursor = .{ .on = try prev_node.size() - 1 };
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
            structural_generation: u64,
        };

        pub fn init(model: *ModelT, repalance_policy: RebalancePolicy) Self {
            return Self{
                .model = model,
                .rebalance_policy = repalance_policy,
            };
        }

        pub fn deinit(_: Self) void {
            // nothing to do for now :)
        }

        /// Releases every page reachable from the current root.
        ///
        /// This bypasses normal rebalancing, so callers must ensure the tree is
        /// no longer reachable before invoking it.
        pub fn destroy(self: *Self) Error!void {
            var mutation = try self.model.structuralMutationCoordinator().beginStructuralMutation();
            defer mutation.deinit();
            const accessor = self.model.accessor();
            const root_id = accessor.getRoot() orelse return;
            try self.destroyNode(root_id);
            try accessor.setRoot(null);
        }

        fn destroyNode(self: *Self, node_id: NodeIdType) Error!void {
            const accessor = self.model.accessor();
            if (try accessor.loadLeaf(node_id)) |leaf_value| {
                const leaf = leaf_value;
                accessor.deinitLeaf(leaf);
                return accessor.destroy(node_id);
            }
            if (try accessor.loadInode(node_id)) |inode_value| {
                var inode = inode_value;
                errdefer accessor.deinitInode(inode);
                const child_count = try inode.size() + 1;
                for (0..child_count) |index| {
                    try self.destroyNode(try inode.getChild(index));
                }
                accessor.deinitInode(inode);
                return accessor.destroy(node_id);
            }
            return error.ChildNotFoundInParent;
        }

        pub fn iterator(self: *const Self) Error!?Iterator {
            const accessor = self.model.accessor();
            if (accessor.getRoot()) |root_id| {
                if (try self.getLeftMostLeafId(root_id)) |left_id| {
                    return try Iterator.init(self.model, left_id, .before_first);
                }
            }
            return null;
        }

        pub fn scanInodeRefs(
            self: *const Self,
            page_id: PageId,
            page: []const u8,
            visitor: anytype,
        ) !void {
            return self.model.scanInodeRefs(page_id, page, visitor);
        }

        pub fn scanLeafRefs(
            self: *const Self,
            page_id: PageId,
            page: []const u8,
            visitor: anytype,
        ) !void {
            return self.model.scanLeafRefs(page_id, page, visitor);
        }

        pub fn iteratorFromEnd(self: *const Self) Error!?Iterator {
            const accessor = self.model.accessor();
            if (accessor.getRoot()) |root_id| {
                if (try self.getRightMostLeafId(root_id)) |right_id| {
                    return try Iterator.init(self.model, right_id, .after_last);
                }
            }
            return null;
        }

        pub fn find(self: *const Self, key: KeyLikeType) Error!?Iterator {
            const accessor = self.model.accessor();
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

        pub fn lowerBound(self: *const Self, key: KeyLikeType) Error!?Iterator {
            const accessor = self.model.accessor();
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

        pub fn dump(self: *Self) Error!void {
            const accessor = self.model.accessor();
            if (accessor.getRoot()) |root| {
                try self.dumpNode(root, 0, null, null);
            } else {
                std.debug.print("<Empty>\n", .{});
            }
        }

        pub fn dumpFormatted(
            self: *Self,
            comptime keyFormatter: ?fn (KeyLikeType) []const u8,
            comptime valueFormatter: ?fn (ValueInType) []const u8,
        ) !void {
            const accessor = self.model.accessor();
            if (accessor.getRoot()) |root| {
                try self.dumpNode(root, 0, keyFormatter, valueFormatter);
            } else {
                std.debug.print("<Empty>\n", .{});
            }
        }

        fn dumpNode(
            self: *Self,
            node_id: NodeIdType,
            level: usize,
            comptime keyFormatter: ?fn (KeyLikeType) []const u8,
            comptime valueFormatter: ?fn (ValueInType) []const u8,
        ) Error!void {
            const accessor = self.model.accessor();

            // Print indentation
            for (0..level) |_| {
                std.debug.print("  ", .{});
            }

            if (try accessor.loadLeaf(node_id)) |const_leaf| {
                defer accessor.deinitLeaf(const_leaf);
                var leaf = const_leaf;
                // It's a leaf node
                std.debug.print("<id:{} p:{?} size:{}> * [", .{ leaf.id(), leaf.getParent(), try leaf.size() });

                const n = try leaf.size();
                for (0..n) |i| {
                    if (i > 0) {
                        std.debug.print(", ", .{});
                    }
                    const key = try leaf.getKey(i);
                    const value = try leaf.getValue(i);

                    if (keyFormatter) |fmt| {
                        std.debug.print("{s}", .{fmt(key)});
                    } else {
                        std.debug.print("{any}", .{key});
                    }

                    std.debug.print(": '", .{});

                    if (valueFormatter) |fmt| {
                        std.debug.print("{s}", .{fmt(value)});
                    } else {
                        std.debug.print("{any}", .{value});
                    }

                    std.debug.print("'", .{});
                }
                std.debug.print("]\n", .{});
            } else if (try accessor.loadInode(node_id)) |inode| {
                defer accessor.deinitInode(inode);

                // It's an inode
                const n = try inode.size();
                std.debug.print("<id:{} p:{?} size:{}> [", .{ inode.id(), inode.getParent(), n });

                for (0..n) |i| {
                    if (i > 0) {
                        std.debug.print(", ", .{});
                    }
                    const key = try inode.getKey(i);

                    if (keyFormatter) |fmt| {
                        std.debug.print("{s}", .{fmt(key)});
                    } else {
                        std.debug.print("{any}", .{key});
                    }
                }
                std.debug.print("] children: {}\n", .{n + 1});

                // Recursively dump children
                for (0..n + 1) |i| {
                    const child_id = try inode.getChild(i);
                    //std.debug.print("level: {} got child {} {} inodesize: {}\n", .{ level, i, child_id, try inode.size() });
                    if (self.model.isValidId(child_id)) {
                        try self.dumpNode(child_id, level + 1, keyFormatter, valueFormatter);
                    }
                }
            } else {
                std.debug.print("<Invalid node: {}>\n", .{node_id});
            }
        }

        pub fn insert(self: *Self, key: KeyLikeType, value: ValueInType) Error!bool {
            var mutation = try self.model.structuralMutationCoordinator().beginStructuralMutation();
            defer mutation.deinit();
            const accessor = self.model.accessor();
            if (accessor.getRoot()) |root| {
                const search = try self.findLeafWith(key, root);
                defer accessor.deinitLeaf(search.leaf);
                if (!search.found) {
                    var leaf = search.leaf.?;
                    if (try leaf.canInsertValue(search.position, key, value)) {
                        try leaf.insertValue(search.position, key, value);
                        //std.debug.print("Key {any} inserted into leaf id: {}\n", .{ key, leaf.id() });
                    } else {
                        var position = search.position;
                        if (self.rebalance_policy == .neighbor_share) {
                            const share = try self.tryLeafNeighborShare(
                                &leaf,
                                key,
                                value,
                                position,
                            );
                            if (share.inserted) {
                                return true;
                            }
                            position = share.position;
                        }
                        try self.handleLeafOverflowDefault(&leaf, key, value, position);
                    }
                    return true;
                } else {
                    //std.debug.print("Key {any} already exists in leaf id: {}\n", .{ key, search.leaf.?.id() });
                }
            } else {
                var leaf = try accessor.createLeaf();
                errdefer accessor.destroy(leaf.id()) catch {};
                defer accessor.deinitLeaf(leaf);
                try leaf.insertValue(0, key, value);
                //std.debug.print("Created leaf node with id: {}\n", .{leafId.id()});
                try accessor.setRoot(leaf.id());
                return true;
            }
            return false;
        }

        pub fn update(self: *Self, key: KeyLikeType, value: ValueInType) Error!bool {
            var mutation = try self.model.structuralMutationCoordinator().beginStructuralMutation();
            defer mutation.deinit();
            const accessor = self.model.accessor();
            if (accessor.getRoot()) |root| {
                const search = try self.findLeafWith(key, root);
                if (search.leaf) |leaf_const| {
                    var leaf = leaf_const;
                    defer accessor.deinitLeaf(leaf);
                    if (search.found) {
                        var position = search.position;
                        while (!try leaf.canUpdateValue(position, value)) {
                            if (try leaf.size() <= 1) {
                                return Error.NotEnoughSpaceForUpdate;
                            }

                            var right = try self.handleLeafOverflow(&leaf);
                            defer accessor.deinitLeaf(right);
                            const left_size = try leaf.size();
                            if (position >= left_size) {
                                position -= left_size;
                                const next = try right.take();
                                accessor.deinitLeaf(leaf);
                                leaf = next;
                            }
                        }
                        try leaf.updateValue(position, value);
                        return true;
                    }
                }
            }
            return false;
        }

        pub fn remove(self: *Self, key: KeyLikeType) Error!bool {
            var mutation = try self.model.structuralMutationCoordinator().beginStructuralMutation();
            defer mutation.deinit();
            const accessor = self.model.accessor();
            if (accessor.getRoot()) |root| {
                const search = try self.findLeafWith(key, root);
                if (search.leaf) |leaf_const| {
                    const removed = blk: {
                        var leaf = leaf_const;
                        defer accessor.deinitLeaf(leaf);
                        if (!search.found) {
                            break :blk false;
                        }
                        try self.removeImpl(&leaf, search.position);
                        break :blk true;
                    };
                    if (removed) {
                        try self.fixEmptyRoot();
                        return true;
                    }
                }
            }
            return false;
        }

        /// Opens the exact mutable bytes of an existing fixed-size value.
        /// The returned editor keeps its leaf and page layout alive until deinit.
        pub fn openValueEditor(self: *Self, key: KeyLikeType) Error!?ValueEditor {
            const accessor = self.model.accessor();
            const root = accessor.getRoot() orelse return null;
            const search = try self.findLeafWith(key, root);
            const leaf_const = search.leaf orelse return null;
            var leaf = leaf_const;
            if (!search.found) {
                accessor.deinitLeaf(leaf);
                return null;
            }
            const editor = accessor.openValueEditor(&leaf, search.position) catch |err| {
                accessor.deinitLeaf(leaf);
                return err;
            };
            accessor.deinitLeaf(leaf);
            return .{
                .editor = editor,
            };
        }

        // private methods

        fn removeImpl(self: *Self, leaf: *LeafType, pos: usize) Error!void {
            const accessor = self.model.accessor();
            const key = try accessor.borrowKeyfromLeaf(leaf, pos);
            defer accessor.deinitBorrowKey(key);

            try leaf.erase(pos);
            if (pos == 0 and try leaf.size() > 0) {
                try self.fixParentIndexImpl(leaf);
            }
            try self.leafHandleUnderflow(leaf, self.model.keyBorrowAsLike(&key));
        }

        fn inodeHandleUnderflow(self: *Self, inode: *InodeType, key: KeyLikeType) Error!void {
            const accessor = self.model.accessor();
            const key_pos = try inode.keyPosition(key);
            if (key_pos > 0 and key_pos <= try inode.size()) {
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
                        try self.updateInodeKeyImpl(inode, key_pos - 1, key_like);
                    } else {
                        @breakpoint();
                        return Error.InvalidId;
                    }
                }
            }

            if (!try self.inodeTryMerge(inode) and try inode.isUnderflowed()) {
                _ = try self.inodeTryBorrow(inode, 0);
            }

            if (try self.loadParentForInode(inode)) |parent_const| {
                var parent = parent_const;
                defer accessor.deinitInode(parent);
                try self.inodeHandleUnderflow(&parent, key);
            }
        }

        fn leafHandleUnderflow(self: *Self, leaf: *LeafType, key: KeyLikeType) Error!void {
            const accessor = self.model.accessor();

            if (!try self.leafTryMerge(leaf) and try leaf.isUnderflowed()) {
                _ = try self.leafTryBorrow(leaf, 0);
            }

            if (try self.loadParentForLeaf(leaf)) |parent_const| {
                var parent = parent_const;
                defer accessor.deinitInode(parent);
                try self.inodeHandleUnderflow(&parent, key);
                try self.fixParentIndexImpl(leaf);
            }
        }

        fn fixEmptyRoot(self: *Self) Error!void {
            const accessor = self.model.accessor();
            if (accessor.getRoot()) |root_id| {
                if (try accessor.loadLeaf(root_id)) |root_leaf| {
                    const empty = blk: {
                        defer accessor.deinitLeaf(root_leaf);
                        break :blk try root_leaf.size() == 0;
                    };
                    if (empty) {
                        try accessor.setRoot(null);
                        try accessor.destroy(root_id);
                    }
                } else if (try accessor.loadInode(root_id)) |root_inode| {
                    const child_id = blk: {
                        defer accessor.deinitInode(root_inode);
                        if (try root_inode.size() != 0) {
                            break :blk null;
                        }
                        break :blk try root_inode.getChild(0);
                    };
                    if (child_id) |id| {
                        try self.setChildParent(id, null);
                        try accessor.setRoot(id);
                        try accessor.destroy(root_id);
                    }
                }
            }
        }

        fn getLeftMostLeafId(self: *const Self, from: NodeIdType) Error!?NodeIdType {
            const accessor = self.model.accessor();
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

        fn getRightMostLeafId(self: *const Self, from: NodeIdType) Error!?NodeIdType {
            const accessor = self.model.accessor();
            if (!self.model.isValidId(from)) {
                return null;
            }
            var res = from;
            while (!try accessor.isLeafId(res)) {
                if (try accessor.loadInode(res)) |next| {
                    defer accessor.deinitInode(next);
                    res = try next.getChild(try next.size());
                }
            }
            return res;
        }

        const LeafNeighborShareResult = struct {
            inserted: bool,
            position: usize,
        };

        // Borrow enough bytes from siblings for the pending variable-sized entry.
        fn tryLeafNeighborShare(
            self: *Self,
            leaf: *LeafType,
            key: KeyLikeType,
            value: ValueInType,
            position: usize,
        ) Error!LeafNeighborShareResult {
            var insert_position = position;
            while (!try leaf.canInsertValue(insert_position, key, value)) {
                if (insert_position > 0 and try self.leafGiveToLeft(leaf, 0)) {
                    insert_position -= 1;
                    continue;
                }

                const leaf_size = try leaf.size();
                if (insert_position < leaf_size and try self.leafGiveToRight(leaf, 0)) {
                    continue;
                }
                return .{ .inserted = false, .position = insert_position };
            }

            try leaf.insertValue(insert_position, key, value);
            if (insert_position == 0) {
                try self.fixParentIndexImpl(leaf);
            }
            return .{ .inserted = true, .position = insert_position };
        }

        fn leafGiveToLeft(self: *Self, leaf: *LeafType, additional_elements: usize) Error!bool {
            const parent_id = leaf.getParent();
            if (!self.model.isValidId(parent_id)) {
                return false;
            }
            const accessor = self.model.accessor();
            if (try accessor.loadInode(parent_id)) |parent| {
                defer accessor.deinitInode(parent);

                if (try self.findLeftSibling(parent.id(), leaf.id())) |left_sibling_id| {
                    if (try accessor.loadLeaf(left_sibling_id)) |left_sibling_const| {
                        defer accessor.deinitLeaf(left_sibling_const);
                        var left_sibling = left_sibling_const;
                        if (try left_sibling.size() < (try left_sibling.capacity() - additional_elements)) {
                            return try self.leafBorrowFromRight(&left_sibling, leaf, additional_elements);
                        }
                    }
                }
            }
            return false;
        }

        fn leafGiveToRight(self: *Self, leaf: *LeafType, additional_elements: usize) Error!bool {
            const parent_id = leaf.getParent();
            if (!self.model.isValidId(parent_id)) {
                return false;
            }
            const accessor = self.model.accessor();
            if (try accessor.loadInode(parent_id)) |parent| {
                defer accessor.deinitInode(parent);

                if (try self.findRightSibling(parent.id(), leaf.id())) |right_sibling_id| {
                    if (try accessor.loadLeaf(right_sibling_id)) |right_sibling_const| {
                        defer accessor.deinitLeaf(right_sibling_const);
                        var right_sibling = right_sibling_const;
                        if (try right_sibling.size() < (try right_sibling.capacity() - additional_elements)) {
                            //std.debug.print("right_sibling id: {}\n", .{right_sibling.id()});
                            return try self.leafBorrowFromLeft(&right_sibling, leaf, additional_elements);
                        }
                    }
                }
            }
            return false;
        }

        fn inodeGiveToLeft(self: *Self, inode: *InodeType, additional_elements: usize) Error!bool {
            const parent_id = inode.getParent();
            if (!self.model.isValidId(parent_id)) {
                return false;
            }
            const accessor = self.model.accessor();
            if (try accessor.loadInode(parent_id)) |parent| {
                defer accessor.deinitInode(parent);
                if (try self.findLeftSibling(parent.id(), inode.id())) |left_sibling_id| {
                    if (try accessor.loadInode(left_sibling_id)) |left_sibling_const| {
                        defer accessor.deinitInode(left_sibling_const);
                        var left_sibling = left_sibling_const;
                        if (try left_sibling.size() < (try left_sibling.capacity() - additional_elements)) {
                            return try self.inodeBorrowFromRight(&left_sibling, inode, additional_elements);
                        }
                    }
                }
            }
            return false;
        }

        fn inodeGiveToRight(self: *Self, inode: *InodeType, additional_elements: usize) Error!bool {
            const parent_id = inode.getParent();
            if (!self.model.isValidId(parent_id)) {
                return false;
            }
            const accessor = self.model.accessor();
            if (try accessor.loadInode(parent_id)) |parent| {
                defer accessor.deinitInode(parent);
                if (try self.findRightSibling(parent.id(), inode.id())) |right_sibling_id| {
                    if (try accessor.loadInode(right_sibling_id)) |right_sibling_const| {
                        defer accessor.deinitInode(right_sibling_const);
                        var right_sibling = right_sibling_const;
                        if (try right_sibling.size() < (try right_sibling.capacity() - additional_elements)) {
                            return try self.inodeBorrowFromLeft(&right_sibling, inode, additional_elements);
                        }
                    }
                }
            }
            return false;
        }

        fn leafBorrowFromLeft(self: *Self, leaf: *LeafType, left: *LeafType, additional_elements: usize) Error!bool {
            const max_elements = try leaf.capacity();
            const min_elements = (max_elements + 1) / 2 - 1;
            const accessor = self.model.accessor();
            if (try left.size() > (min_elements + additional_elements)) {
                const key_to_check = try left.getKey(try left.size() - 1);
                const key_like = self.model.keyOutAsLike(key_to_check);
                if (try accessor.loadInode(leaf.getParent())) |parent_const| {
                    defer accessor.deinitInode(parent_const);
                    var parent = parent_const;
                    const pos_in_parent = try self.findChidIndexInParentId(parent.id(), leaf.id());
                    if (try parent.canUpdateKey(pos_in_parent - 1, key_like)) {
                        const out_key = try left.getKey(try left.size() - 1);
                        const out_value = try left.getValue(try left.size() - 1);

                        const key = self.model.keyOutAsLike(out_key);
                        const value = self.model.valueOutAsIn(out_value);

                        if (!try leaf.canInsertValue(0, key, value)) {
                            return false;
                        }

                        try leaf.insertValue(0, key, value);
                        try left.erase(try left.size() - 1);
                        try parent.updateKey(pos_in_parent - 1, self.model.keyOutAsLike(try leaf.getKey(0)));
                        return true;
                    }
                }
            }
            return false;
        }

        fn leafBorrowFromRight(self: *Self, leaf: *LeafType, right: *LeafType, additional_elements: usize) Error!bool {
            const max_elements = try leaf.capacity();
            const min_elements = (max_elements + 1) / 2 - 1;
            const accessor = self.model.accessor();
            if (try right.size() > (min_elements + additional_elements)) {
                const key_to_check = try right.getKey(1);
                const key_like = self.model.keyOutAsLike(key_to_check);
                if (try accessor.loadInode(leaf.getParent())) |parent_const| {
                    defer accessor.deinitInode(parent_const);

                    var parent = parent_const;
                    const pos_in_parent = try self.findChidIndexInParentId(parent.id(), leaf.id());
                    if (try parent.canUpdateKey(pos_in_parent, key_like)) {
                        const out_key = try right.getKey(0);
                        const out_value = try right.getValue(0);

                        const key = self.model.keyOutAsLike(out_key);
                        const value = self.model.valueOutAsIn(out_value);

                        const insert_position = try leaf.size();
                        if (!try leaf.canInsertValue(insert_position, key, value)) {
                            return false;
                        }

                        try leaf.insertValue(insert_position, key, value);
                        try right.erase(0);
                        try parent.updateKey(pos_in_parent, self.model.keyOutAsLike(try right.getKey(0)));
                        return true;
                    }
                }
            }
            return false;
        }

        fn leafTryBorrowFromLeft(self: *Self, leaf: *LeafType, additional_elements: usize) Error!bool {
            const parent_id = leaf.getParent();
            if (!self.model.isValidId(parent_id)) {
                return false;
            }
            const accessor = self.model.accessor();
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

        fn leafTryBorrowFromRight(self: *Self, leaf: *LeafType, additional_elements: usize) Error!bool {
            const parent_id = leaf.getParent();
            if (!self.model.isValidId(parent_id)) {
                return false;
            }
            const accessor = self.model.accessor();
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

        fn leafTryBorrow(self: *Self, leaf: *LeafType, additional_elements: usize) Error!bool {
            if (try self.leafTryBorrowFromLeft(leaf, additional_elements)) {
                return true;
            }
            if (try self.leafTryBorrowFromRight(leaf, additional_elements)) {
                return true;
            }
            return false;
        }

        fn inodeBorrowFromLeft(self: *Self, inode: *InodeType, left: *InodeType, additional_elements: usize) Error!bool {
            const max_elements = try inode.capacity();
            const min_elements = (max_elements + 1) / 2 - 1;
            const accessor = self.model.accessor();
            if (try left.size() > min_elements + additional_elements) {
                if (try accessor.loadInode(inode.getParent())) |parent_const| {
                    defer accessor.deinitInode(parent_const);
                    var parent = parent_const;
                    const pos_in_parent = try self.findChidIndexInParentId(parent.id(), inode.id());

                    const borrow_parent_key = try accessor.borrowKeyfromInode(&parent, pos_in_parent - 1);
                    defer accessor.deinitBorrowKey(borrow_parent_key);

                    const borrow_key = try accessor.borrowKeyfromInode(left, try left.size() - 1);
                    defer accessor.deinitBorrowKey(borrow_key);

                    const parent_key = self.model.keyBorrowAsLike(&borrow_parent_key);
                    const key = self.model.keyBorrowAsLike(&borrow_key);
                    const child_id = try left.getChild(try left.size()); // right most child

                    try self.setChildParent(child_id, inode.id());
                    try inode.insertChild(0, parent_key, child_id);

                    // TODO: check if we can use getKey here instead
                    try self.updateInodeKeyImpl(&parent, pos_in_parent - 1, key);

                    try self.swapChildren(left, try left.size(), try left.size() - 1);
                    try left.erase(try left.size() - 1);

                    return true;
                }
            }
            return false;
        }

        fn inodeBorrowFromRight(self: *Self, inode: *InodeType, right: *InodeType, additional_elements: usize) Error!bool {
            const max_elements = try inode.capacity();
            const min_elements = (max_elements + 1) / 2 - 1;
            const accessor = self.model.accessor();
            if (try right.size() > min_elements + additional_elements) {
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
                    try self.updateInodeKeyImpl(&parent, pos_in_parent, key);

                    const last_child = try inode.getChild(try inode.size());
                    try inode.insertChild(try inode.size(), parent_key, last_child);
                    try inode.updateChild(try inode.size(), child_id);

                    try right.erase(0);

                    return true;
                }
            }
            return false;
        }

        fn inodeTryBorrowLeft(self: *Self, inode: *InodeType, additional_elements: usize) Error!bool {
            const parent_id = inode.getParent();
            if (!self.model.isValidId(parent_id)) {
                return false;
            }
            const accessor = self.model.accessor();
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

        fn inodeTryBorrowRight(self: *Self, inode: *InodeType, additional_elements: usize) Error!bool {
            const parent_id = inode.getParent();
            if (!self.model.isValidId(parent_id)) {
                return false;
            }
            const accessor = self.model.accessor();
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

        fn inodeTryBorrow(self: *Self, inode: *InodeType, additional_elements: usize) Error!bool {
            if (try self.inodeTryBorrowLeft(inode, additional_elements)) {
                return true;
            }
            if (try self.inodeTryBorrowRight(inode, additional_elements)) {
                return true;
            }
            return false;
        }

        // Merging nodes
        fn leafMergeWithRight(self: *Self, leaf: *LeafType) Error!bool {
            const accessor = self.model.accessor();
            if (try accessor.loadInode(leaf.getParent())) |parent_const| {
                defer accessor.deinitInode(parent_const);

                if (try self.findRightSibling(parent_const.id(), leaf.id())) |right_id| {
                    if (try accessor.loadLeaf(right_id)) |right_sibling_const| {
                        // we need to deinit leaf defore destroy
                        const right_pos = blk: {
                            defer accessor.deinitLeaf(right_sibling_const);
                            var right_sibling = right_sibling_const;
                            if (!try accessor.canMergeLeafs(leaf, &right_sibling)) {
                                break :blk null;
                            }
                            for (0..try right_sibling.size()) |i| {
                                const out_key = try right_sibling.getKey(i);
                                const out_value = try right_sibling.getValue(i);

                                const key = self.model.keyOutAsLike(out_key);
                                const value = self.model.valueOutAsIn(out_value);

                                try leaf.insertValue(try leaf.size(), key, value);
                            }
                            try leaf.setNext(right_sibling.getNext());
                            if (right_sibling.getNext()) |next_id| {
                                if (try accessor.loadLeaf(next_id)) |next_leaf_const| {
                                    defer accessor.deinitLeaf(next_leaf_const);
                                    var next_leaf = next_leaf_const;
                                    try next_leaf.setPrev(leaf.id());
                                }
                            }
                            break :blk try self.findChidIndexInParentId(parent_const.id(), right_id);
                        };
                        if (right_pos) |pos| {
                            var parent = parent_const;
                            try self.swapChildren(&parent, pos - 1, pos);
                            try accessor.destroy(right_id);
                            try parent.erase(pos - 1);
                            return true;
                        }
                    }
                }
            }
            return false;
        }

        // In this case, we delete the current node and transfer data from the left sibling into it.
        // TODO do not delete this for a while...
        // In theory, this should slightly optimize deletion,
        // but it makes the current iterator invalid and we won't be able to return the next element.
        // fn leafMergeWithLeft(self: *Self, leaf: *LeafType) Error!bool {
        //     const accessor = self.model.accessor();
        //     if (try self.findLeftSibling(leaf.getParent(), leaf.id())) |left_id| {
        //         if (try accessor.loadLeaf(left_id)) |left_sibling_const| {
        //             var left_sibling = left_sibling_const;
        //             defer accessor.deinitLeaf(left_sibling);
        //             if (try self.leafMergeWithRight(&left_sibling)) {
        //                 accessor.deinitLeaf(leaf.*);
        //                 leaf.* = try left_sibling.take();
        //                 return true;
        //             }
        //         }
        //     }
        //     return false;
        // }

        // So, we are deleting the left node here, and keeping the current one valid.
        // This will not break the iterator, if we want to delete via iterator.
        /// TODO it needs to be tested well...
        fn leafMergeWithLeft(self: *Self, leaf: *LeafType) Error!bool {
            const accessor = self.model.accessor();
            if (try accessor.loadInode(leaf.getParent())) |parent_const| {
                defer accessor.deinitInode(parent_const);

                if (try self.findLeftSibling(parent_const.id(), leaf.id())) |left_id| {
                    if (try accessor.loadLeaf(left_id)) |left_sibling_const| {
                        // we need to deinit leaf defore destroy
                        const left_pos = blk: {
                            defer accessor.deinitLeaf(left_sibling_const);
                            var left_sibling = left_sibling_const;
                            if (!try accessor.canMergeLeafs(leaf, &left_sibling)) {
                                break :blk null;
                            }
                            for (0..try left_sibling.size()) |i| {
                                const out_key = try left_sibling.getKey(i);
                                const out_value = try left_sibling.getValue(i);

                                const key = self.model.keyOutAsLike(out_key);
                                const value = self.model.valueOutAsIn(out_value);

                                try leaf.insertValue(i, key, value);
                            }
                            try leaf.setPrev(left_sibling.getPrev());
                            if (left_sibling.getPrev()) |prev_id| {
                                if (try accessor.loadLeaf(prev_id)) |prev_leaf_const| {
                                    defer accessor.deinitLeaf(prev_leaf_const);
                                    var prev_leaf = prev_leaf_const;
                                    try prev_leaf.setNext(leaf.id());
                                }
                            }
                            break :blk try self.findChidIndexInParentId(parent_const.id(), left_id);
                        };
                        if (left_pos) |pos| {
                            var parent = parent_const;
                            try accessor.destroy(left_id);
                            try parent.erase(pos);
                            return true;
                        }
                    }
                }
            }
            return false;
        }

        fn leafTryMerge(self: *Self, leaf: *LeafType) Error!bool {
            if (try leaf.size() == 0) {
                //@breakpoint();
            }

            if (try self.leafMergeWithRight(leaf)) {
                //std.debug.print("Merged leaf id: {} with right sibling\n", .{leaf.id()});
                return true;
            }
            if (try self.leafMergeWithLeft(leaf)) {
                //std.debug.print("Merged leaf id: {} with left sibling\n", .{leaf.id()});
                //return try self.model.accessor().loadLeaf(merged.id());
                return true;
            }
            return false;
        }

        fn mergeInodes(
            self: *Self,
            left: *InodeType,
            right: *InodeType,
            parent: *InodeType,
            right_pos: usize,
        ) Error!void {
            const separator_key_out = try parent.getKey(right_pos - 1);
            const separator_key = self.model.keyOutAsLike(separator_key_out);
            const last_left_child = try left.getChild(try left.size());

            try left.insertChild(try left.size(), separator_key, last_left_child);
            for (0..try right.size()) |index| {
                const out_key = try right.getKey(index);
                const child_id = try right.getChild(index);
                const key = self.model.keyOutAsLike(out_key);

                try left.insertChild(try left.size(), key, child_id);
                try self.setChildParent(child_id, left.id());
            }

            const right_most_child = try right.getChild(try right.size());
            try left.updateChild(try left.size(), right_most_child);
            try self.setChildParent(right_most_child, left.id());
            try self.swapChildren(parent, right_pos - 1, right_pos);
            try parent.erase(right_pos - 1);
        }

        fn inodeMergeWithRight(self: *Self, inode: *InodeType) Error!bool {
            const accessor = self.model.accessor();
            if (try self.findRightSibling(inode.getParent(), inode.id())) |right_id| {
                if (try accessor.loadInode(right_id)) |right_sibling_const| {
                    const merged = blk: {
                        defer accessor.deinitInode(right_sibling_const);
                        var right_sibling = right_sibling_const;
                        if (!try accessor.canMergeInodes(inode, &right_sibling)) {
                            break :blk false;
                        }
                        if (try accessor.loadInode(inode.getParent())) |parent_const| {
                            defer accessor.deinitInode(parent_const);
                            var parent = parent_const;
                            const right_pos = try self.findChidIndexInParentId(parent.id(), right_id);
                            try self.mergeInodes(inode, &right_sibling, &parent, right_pos);
                            break :blk true;
                        }
                        break :blk false;
                    };
                    if (merged) {
                        try accessor.destroy(right_id);
                        return true;
                    }
                }
            }
            return false;
        }

        fn inodeMergeWithLeft(self: *Self, inode: *InodeType) Error!bool {
            const accessor = self.model.accessor();
            if (try self.findLeftSibling(inode.getParent(), inode.id())) |left_id| {
                if (try accessor.loadInode(left_id)) |left_sibling_const| {
                    var left_sibling = left_sibling_const;
                    defer accessor.deinitInode(left_sibling);
                    if (!try accessor.canMergeInodes(&left_sibling, inode)) {
                        return false;
                    }
                    const destroyed_id = blk: {
                        if (try accessor.loadInode(inode.getParent())) |parent_const| {
                            defer accessor.deinitInode(parent_const);
                            var parent = parent_const;
                            const target_id = inode.id();
                            const right_pos = try self.findChidIndexInParentId(parent.id(), target_id);
                            try self.mergeInodes(&left_sibling, inode, &parent, right_pos);

                            const survivor = try left_sibling.take();
                            accessor.deinitInode(inode.*);
                            inode.* = survivor;
                            break :blk target_id;
                        }
                        break :blk null;
                    };
                    if (destroyed_id) |target_id| {
                        try accessor.destroy(target_id);
                        return true;
                    }
                }
            }
            return false;
        }

        fn inodeTryMerge(self: *Self, inode: *InodeType) Error!bool {
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

        fn findLeafWith(self: *const Self, key: KeyLikeType, id: NodeIdType) Error!SearchResult {
            const accessor = self.model.accessor();
            const not_found = SearchResult{
                .leaf = null,
                .position = 0,
                .found = false,
            };
            var current: NodeIdType = id;
            while (true) {
                if (try accessor.loadLeaf(current)) |leaf_const| {
                    var leaf = leaf_const;
                    defer accessor.deinitLeaf(leaf);
                    const keyPos = leaf.keyPosition(key) catch return not_found;
                    if (keyPos < try leaf.size()) {
                        const existingKey = try leaf.getKey(keyPos);
                        const eq = leaf.keysEqual(self.model.keyOutAsLike(existingKey), key);
                        return .{ .leaf = try leaf.take(), .position = keyPos, .found = eq };
                    }
                    return .{ .leaf = try leaf.take(), .position = keyPos, .found = false };
                } else if (try accessor.loadInode(current)) |inode| {
                    defer accessor.deinitInode(inode);
                    const keyPos = inode.keyPosition(key) catch return not_found;
                    current = try inode.getChild(keyPos);
                } else {
                    return Error.InvalidId;
                }
            }
        }

        fn handleLeafOverflowDefault(self: *Self, leaf: *LeafType, key: KeyLikeType, value: ValueInType, pos: usize) Error!void {
            var res = try self.handleLeafOverflow(leaf);
            defer self.model.accessor().deinitLeaf(res);
            if (try leaf.size() < pos) {
                const insert_pos = pos - try leaf.size();
                if (try res.canInsertValue(insert_pos, key, value)) {
                    try res.insertValue(insert_pos, key, value);
                    if (insert_pos == 0) {
                        try self.fixParentIndexImpl(&res);
                    }
                } else {
                    try self.handleLeafOverflowDefault(&res, key, value, insert_pos);
                }
            } else {
                if (try leaf.canInsertValue(pos, key, value)) {
                    try leaf.insertValue(pos, key, value);
                    if (pos == 0) {
                        try self.fixParentIndexImpl(leaf);
                    }
                } else {
                    try self.handleLeafOverflowDefault(leaf, key, value, pos);
                }
            }
        }

        const PreparedParentInsert = struct {
            parent: InodeType,
            position: usize,
            left_child: NodeIdType,
        };

        fn prepareParentInsertExact(
            self: *Self,
            child: anytype,
            key: KeyLikeType,
        ) Error!PreparedParentInsert {
            const accessor = self.model.accessor();
            while (true) {
                const parent_id = child.getParent();
                if (!self.model.isValidId(parent_id)) {
                    return Error.NoParent;
                }

                var parent = (try accessor.loadInode(parent_id)) orelse return Error.InvalidId;
                defer accessor.deinitInode(parent);

                const position = try self.findChidIndexInParentId(parent.id(), child.id());
                const left_child = try parent.getChild(position);
                if (left_child != child.id()) {
                    return Error.ChildNotFoundInParent;
                }
                if (try parent.canInsertChild(position, key, left_child)) {
                    return .{
                        .parent = try parent.take(),
                        .position = position,
                        .left_child = left_child,
                    };
                }

                try self.handleInodeOverflowDefault(
                    &parent,
                    key,
                    left_child,
                    position,
                );
            }
        }

        fn handleLeafOverflow(self: *Self, leaf: *LeafType) Error!LeafType {
            const leaf_if = leaf.id();
            const accessor = self.model.accessor();
            var new_root: ?InodeType = null;
            defer accessor.deinitInode(new_root);

            if (!self.model.isValidId(leaf.getParent())) {
                new_root = try accessor.createInode();
            }
            var split_result = try self.splitLeaf(leaf);
            var right_leaf = try split_result.right.take();
            defer accessor.deinitLeaf(right_leaf);

            if (new_root) |nr_const| { // leaf is root
                var nr = nr_const;
                try right_leaf.setParent(nr.id());
                try leaf.setParent(nr.id());

                const first_key = try right_leaf.getKey(0);
                const first_key_like = self.model.keyOutAsLike(first_key);

                try nr.insertChild(0, first_key_like, leaf_if);
                try nr.updateChild(1, right_leaf.id());
                try accessor.setRoot(nr.id());
            } else {
                const key_like = split_result.middle_key;
                var prepared = try self.prepareParentInsertExact(leaf, key_like);
                defer accessor.deinitInode(prepared.parent);

                try right_leaf.setParent(prepared.parent.id());
                try prepared.parent.insertChild(
                    prepared.position,
                    key_like,
                    prepared.left_child,
                );
                try prepared.parent.updateChild(
                    prepared.position + 1,
                    right_leaf.id(),
                );
            }
            return try right_leaf.take();
        }

        // TODO: refactor to avoid code duplication with handleInodeOverflow and error list is too long
        fn handleInodeOverflowDefault(self: *Self, inode: *InodeType, key: KeyLikeType, child_opt: ?NodeIdType, pos: usize) Error!void {
            if (child_opt) |child| {
                if (!try inode.canInsertChild(pos, key, child)) {
                    if (self.rebalance_policy == .neighbor_share) {
                        if (try self.inodeGiveToLeft(inode, 1)) {
                            return;
                        }
                        if (try self.inodeGiveToRight(inode, 1)) {
                            return;
                        }
                    }
                    self.model.accessor().deinitInode(try self.handleInodeOverflow(inode));
                }
            }
        }

        // TODO: refactor to avoid code duplication with handleLeafOverflow
        fn handleInodeOverflow(self: *Self, inode: *InodeType) Error!InodeType {
            const accessor = self.model.accessor();
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
                try inode.setParent(nr.id());
                try nr.insertChild(0, self.model.keyBorrowAsLike(&res.middle_key), inode.id());
                try nr.updateChild(1, right_inode.id());
                try inode.setParent(nr.id());
                try right_inode.setParent(nr.id());
                try accessor.setRoot(nr.id());
            } else {
                const key_like = self.model.keyBorrowAsLike(&res.middle_key);
                var prepared = try self.prepareParentInsertExact(inode, key_like);
                defer accessor.deinitInode(prepared.parent);

                try right_inode.setParent(prepared.parent.id());
                try prepared.parent.insertChild(
                    prepared.position,
                    key_like,
                    prepared.left_child,
                );
                try prepared.parent.updateChild(
                    prepared.position + 1,
                    right_inode.id(),
                );
            }
            return try right_inode.take();
        }

        fn findChidIndexInParentInode(self: *Self, child: *const InodeType) Error!usize {
            const parent_id = child.getParent();
            return self.findChidIndexInParentId(parent_id, child.id());
        }

        fn findChidIndexInParentLeaf(self: *Self, child: *const LeafType) Error!usize {
            const parent_id = child.getParent();
            return self.findChidIndexInParentId(parent_id, child.id());
        }

        fn findChidIndexInParentId(self: *Self, parent_id: ?NodeIdType, child: NodeIdType) Error!usize {
            const accessor = self.model.accessor();
            if (self.model.isValidId(parent_id)) {
                if (try accessor.loadInode(parent_id)) |parent| {
                    defer accessor.deinitInode(parent);

                    const n = try parent.size();
                    for (0..n + 1) |i| { // + right most child
                        const cid = try parent.getChild(i);
                        if (cid == child) {
                            return i;
                        }
                    }
                    return Error.ChildNotFoundInParent;
                } else {
                    return Error.InvalidId;
                }
            } else {
                return Error.NoParent;
            }
        }

        pub fn fixParentIndex(self: *Self, child: *const LeafType) Error!void {
            var mutation = try self.model.structuralMutationCoordinator().beginStructuralMutation();
            defer mutation.deinit();
            return self.fixParentIndexImpl(child);
        }

        fn fixParentIndexImpl(self: *Self, child: *const LeafType) Error!void {
            const accessor = self.model.accessor();
            const parent_id = child.getParent();
            if (self.model.isValidId(parent_id)) {
                if (try accessor.loadInode(parent_id)) |parent_const| {
                    defer accessor.deinitInode(parent_const);
                    var parent = parent_const;
                    const pos = try self.findChidIndexInParentLeaf(child);
                    // TODO: check if update is available
                    if (pos > 0) {
                        try self.updateParentInodeKeyImpl(&parent, pos - 1, child);
                    }
                }
            }
        }

        pub fn updateParentInodeKey(self: *Self, parent: *InodeType, pos: usize, child: *const LeafType) Error!void {
            var mutation = try self.model.structuralMutationCoordinator().beginStructuralMutation();
            defer mutation.deinit();
            return self.updateParentInodeKeyImpl(parent, pos, child);
        }

        fn updateParentInodeKeyImpl(self: *Self, parent: *InodeType, pos: usize, child: *const LeafType) Error!void {
            if (try child.size() == 0) {
                return;
            }
            const first_key = try child.getKey(0);
            try self.updateInodeKeyImpl(parent, pos, self.model.keyOutAsLike(first_key));
        }

        pub fn updateInodeKey(self: *Self, inode: *InodeType, pos: usize, key: KeyLikeType) Error!void {
            var mutation = try self.model.structuralMutationCoordinator().beginStructuralMutation();
            defer mutation.deinit();
            return self.updateInodeKeyImpl(inode, pos, key);
        }

        fn updateInodeKeyImpl(self: *Self, inode: *InodeType, pos: usize, key: KeyLikeType) Error!void {
            const accessor = self.model.accessor();
            if (try inode.canUpdateKey(pos, key)) {
                try inode.updateKey(pos, key);
                return;
            }

            var right = try self.handleInodeOverflow(inode);
            defer accessor.deinitInode(right);
            const left_size = try inode.size();
            if (pos < left_size) {
                return self.updateInodeKeyImpl(inode, pos, key);
            }
            if (pos > left_size) {
                return self.updateInodeKeyImpl(&right, pos - left_size - 1, key);
            }

            var parent = (try accessor.loadInode(inode.getParent())) orelse return Error.InvalidId;
            defer accessor.deinitInode(parent);
            const parent_pos = try self.findChidIndexInParentId(parent.id(), inode.id());
            return self.updateInodeKeyImpl(&parent, parent_pos, key);
        }

        const SplitLeafResult = struct {
            right: LeafType, // todo: do i need here ?
            middle_key: KeyLikeType,
        };

        fn splitLeaf(self: *Self, leaf: *LeafType) Error!SplitLeafResult {
            const maximum = try leaf.size();
            const mid = maximum / 2;
            const mode_id = leaf.id();
            const accessor = self.model.accessor();

            var right = try accessor.createLeaf();
            defer self.model.accessor().deinitLeaf(right);

            for (mid..maximum) |i| {
                const out_key = try leaf.getKey(i);
                const out_value = try leaf.getValue(i);

                const key_like = self.model.keyOutAsLike(out_key);
                const value_in = self.model.valueOutAsIn(out_value);

                try right.insertValue(try right.size(), key_like, value_in);
            }
            try right.setParent(leaf.getParent());
            try right.setPrev(mode_id);
            if (leaf.getNext()) |ln| {
                try right.setNext(ln);
            }
            try leaf.setNext(right.id());
            {
                if (right.getNext()) |next_id| {
                    if (try accessor.loadLeaf(next_id)) |next_leaf_const| {
                        defer accessor.deinitLeaf(next_leaf_const);
                        var next_leaf = next_leaf_const;
                        try next_leaf.setPrev(right.id());
                    }
                }
            }

            for (mid..maximum) |_| {
                try leaf.erase(mid);
            }

            const mid_key = try right.getKey(0);
            return SplitLeafResult{
                .right = try right.take(),
                .middle_key = self.model.keyOutAsLike(mid_key),
            };
        }

        const SplitInodeResult = struct {
            right: InodeType,
            middle_key: KeyBorrowType,
        };

        fn splitInode(self: *Self, inode: *InodeType) Error!SplitInodeResult {
            const accessor = self.model.accessor();
            const maximum = try inode.size();
            const mid = maximum / 2;
            const reduce_size = (maximum - mid);

            var right = try accessor.createInode();
            defer accessor.deinitInode(right);

            const middle_key = try accessor.borrowKeyfromInode(inode, mid);
            errdefer accessor.deinitBorrowKey(middle_key);

            try right.setParent(inode.getParent());
            for (mid + 1..maximum) |i| {
                const out_key = try inode.getKey(i);
                const child_id = try inode.getChild(i);
                const key_like = self.model.keyOutAsLike(out_key);
                try self.setChildParent(child_id, right.id());
                try right.insertChild(try right.size(), key_like, child_id);
            }
            const last_child_id = try inode.getChild(maximum);
            try self.setChildParent(last_child_id, right.id());
            try right.updateChild(try right.size(), last_child_id);
            for (0..reduce_size) |_| {
                const last_child_pos = try inode.size() - 1;
                try self.swapChildren(inode, last_child_pos, last_child_pos + 1);
                try inode.erase(last_child_pos);
            }

            return SplitInodeResult{
                .right = try right.take(),
                .middle_key = middle_key,
            };
        }

        fn swapChildren(_: *const Self, inode: *InodeType, a: usize, b: usize) Error!void {
            const child_a = try inode.getChild(a);
            const child_b = try inode.getChild(b);
            try inode.updateChild(a, child_b);
            try inode.updateChild(b, child_a);
        }

        fn setChildParent(self: *Self, child_id: NodeIdType, parent_id: ?NodeIdType) Error!void {
            const accessor = self.model.accessor();
            if (try accessor.loadInode(child_id)) |child_inode_const| {
                defer accessor.deinitInode(child_inode_const);
                var child_inode = child_inode_const;
                try child_inode.setParent(parent_id);
            } else if (try accessor.loadLeaf(child_id)) |child_leaf_const| {
                defer accessor.deinitLeaf(child_leaf_const);
                var child_leaf = child_leaf_const;
                try child_leaf.setParent(parent_id);
            } else {
                return Error.InvalidId;
            }
        }

        // Sibling finders. It tryes to find siblings only on the same level and the same inode (no climbing up or down the tree)
        fn findLeftSibling(self: *Self, parent_id_opt: ?NodeIdType, child_id_opt: ?NodeIdType) Error!?NodeIdType {
            const accessor = self.model.accessor();
            var parent_id: NodeIdType = undefined;
            var child_id: NodeIdType = undefined;
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

        fn findRightSibling(self: *Self, parent_id: ?NodeIdType, child_id: NodeIdType) Error!?NodeIdType {
            const accessor = self.model.accessor();
            if (try accessor.loadInode(parent_id)) |parent| {
                defer accessor.deinitInode(parent);

                const pos = try self.findChidIndexInParentId(parent.id(), child_id);
                if (pos < try parent.size()) {
                    return try parent.getChild(pos + 1);
                }
            }
            return null;
        }

        fn loadParentForLeaf(self: *Self, leaf: *const LeafType) Error!?InodeType {
            const parent_id = leaf.getParent();
            if (self.model.isValidId(parent_id)) {
                const accessor = self.model.accessor();
                if (try accessor.loadInode(parent_id)) |parent| {
                    return parent;
                }
            }
            return null;
        }

        fn loadParentForInode(self: *Self, inode: *const InodeType) Error!?InodeType {
            const parent_id = inode.getParent();
            if (self.model.isValidId(parent_id)) {
                const accessor = self.model.accessor();
                if (try accessor.loadInode(parent_id)) |parent| {
                    return parent;
                }
            }
            return null;
        }
    };
}
