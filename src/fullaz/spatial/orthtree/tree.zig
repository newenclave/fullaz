const std = @import("std");
const interfaces = @import("models/interfaces.zig");

pub const VisitorResult = enum {
    descend,
    skip_children,
};

pub const TraverseDecision = enum {
    descend,
    accept,
    skip,
};

pub fn TreeImpl(comptime ModelT: type) type {
    comptime {
        interfaces.assertModel(ModelT);
    }

    const ErrorSet = ModelT.Error;

    return struct {
        const Self = @This();
        pub const Error = ErrorSet;
        pub const Model = ModelT;
        pub const AccessorType = Model.AccessorType;
        pub const PageId = if (@hasDecl(Model, "PageId")) Model.PageId else Model.NodeId;
        pub const NodeId = Model.NodeId;
        pub const Node = Model.Node;
        pub const Box = Model.Box;
        pub const Value = Model.ValueIn;
        pub const ValueOut = Model.ValueOut;
        pub const ValueBorrow = Model.ValueBorrow;
        pub const dimension = Box.dimension;
        pub const child_count = 1 << dimension;

        /// A mutable lease for one entry returned by `queryEditable`.
        /// `finish` updates every enclosing trait before committing the value.
        pub const ValueEditor = struct {
            const EditorSelf = @This();

            tree: *Self,
            node_id: NodeId,
            box: Box,
            editor: Model.ValueEditorType,

            pub fn valueMut(self: *EditorSelf) Model.ValueEditorType.Error!Model.ValueEditorType.ValueMut {
                return self.editor.valueMut();
            }

            pub fn finish(self: *EditorSelf) Error!void {
                const old_value = try self.editor.originalValue();
                const new_value = try self.editor.value();
                try self.tree.updateTraitsAlongPath(self.node_id, self.box, old_value, new_value);
                self.editor.finish() catch |err| {
                    self.tree.updateTraitsAlongPath(self.node_id, self.box, new_value, old_value) catch {
                        @panic("OrthTree trait update rollback failed");
                    };
                    return err;
                };
            }

            pub fn deinit(self: *EditorSelf) void {
                self.editor.deinit();
            }
        };

        /// A query callback receives this borrowed handle for its current match.
        /// It can open an editor without consuming or removing the entry.
        pub const EditableQueryHit = struct {
            const HitSelf = @This();

            tree: *Self,
            node: *Node,
            entries: *Node.EntriesMut,
            cursor: *Node.EntriesMut.Cursor,
            box: Box,

            pub fn editValue(self: *HitSelf) Error!ValueEditor {
                return .{
                    .tree = self.tree,
                    .node_id = self.node.id(),
                    .box = self.box,
                    .editor = try self.tree.model.openValueEditor(
                        self.node,
                        self.entries,
                        self.cursor,
                    ),
                };
            }
        };

        model: *Model,

        pub fn init(model: *Model) Self {
            return Self{
                .model = model,
            };
        }

        pub fn scanNodeRefs(
            self: *const Self,
            page_id: PageId,
            page: []const u8,
            visitor: anytype,
        ) !void {
            return self.model.scanNodeRefs(page_id, page, visitor);
        }

        pub fn scanEntryRefs(
            self: *const Self,
            page_id: PageId,
            page: []const u8,
            visitor: anytype,
        ) !void {
            return self.model.scanEntryRefs(page_id, page, visitor);
        }

        fn accessor(self: *const Self) *AccessorType {
            return self.model.accessor();
        }

        pub fn bounds(self: *const Self) Error!?Box {
            const acc = self.accessor();
            if (try acc.getRoot()) |root_id| {
                var root_node = try acc.loadNode(root_id);
                defer acc.deinitNode(&root_node);
                return root_node.bounds();
            }
            return null;
        }

        pub fn initRootBounds(self: *Self, bbox: Box) ErrorSet!void {
            var mutation = try self.model.structuralMutationCoordinator().beginStructuralMutation();
            defer mutation.deinit();
            return self.initRootBoundsImpl(bbox);
        }

        fn initRootBoundsImpl(self: *Self, bbox: Box) ErrorSet!void {
            const acc = self.accessor();
            if (try acc.getRoot()) |_| {
                return ErrorSet.AlreadyInitialized;
            }
            var root_node = try acc.createNode(bbox);
            defer acc.deinitNode(&root_node);
            try acc.setRoot(root_node.id());
        }

        pub fn insert(self: *Self, child_box: Box, value: Value) Error!void {
            var mutation = try self.model.structuralMutationCoordinator().beginStructuralMutation();
            defer mutation.deinit();
            const acc = self.accessor();
            if (try acc.getRoot()) |root_id| {
                const needs_growth = blk: {
                    var root_node = try acc.loadNode(root_id);
                    defer acc.deinitNode(&root_node);
                    break :blk !root_node.bounds().containsBox(&child_box);
                };
                if (needs_growth) {
                    try self.growRootToContainImpl(child_box);
                }

                var root_node = try acc.loadNode((try acc.getRoot()).?);
                defer acc.deinitNode(&root_node);
                try self.insertIntoNodeImpl(&root_node, child_box, value);
                try self.model.incrementEntriesCount();
            } else {
                try self.initRootBoundsImpl(child_box);
                var root_node = try acc.loadNode((try acc.getRoot()).?);
                defer acc.deinitNode(&root_node);
                try self.insertIntoNodeImpl(&root_node, child_box, value);
                try self.model.incrementEntriesCount();
            }
        }

        pub fn query(self: *const Self, qbox: Box, comptime callback: anytype, ctx: anytype) Error!void {
            const acc = self.accessor();
            if (try acc.getRoot()) |root_id| {
                var root_node = try acc.loadNode(root_id);
                defer acc.deinitNode(&root_node);
                try self.queryNode(&root_node, qbox, callback, ctx);
            }
        }

        pub fn queryEditable(self: *Self, qbox: Box, comptime callback: anytype, ctx: anytype) Error!void {
            const acc = self.accessor();
            if (try acc.getRoot()) |root_id| {
                var root_node = try acc.loadNode(root_id);
                defer acc.deinitNode(&root_node);
                try self.queryEditableNode(&root_node, qbox, callback, ctx);
            }
        }

        pub fn remove(self: *Self, qbox: Box, comptime predicate: anytype, ctx: anytype) Error!bool {
            var mutation = try self.model.structuralMutationCoordinator().beginStructuralMutation();
            defer mutation.deinit();
            const acc = self.accessor();
            if (try acc.getRoot()) |root_id| {
                var root_node = try acc.loadNode(root_id);
                defer acc.deinitNode(&root_node);
                if (try self.removeFromNode(&root_node, qbox, predicate, ctx)) |result_const| {
                    var result = result_const;
                    defer self.model.deinitBorrowValue(&result.value);
                    try self.model.finalizeBorrowValue(&result.value);
                    return true;
                }
            }
            return false;
        }

        /// Removes every entry selected by `predicate` within `qbox`.
        /// Partial progress is retained if predicate, trait, count, or cleanup fails.
        pub fn removeIf(self: *Self, qbox: Box, comptime predicate: anytype, ctx: anytype) Error!usize {
            var mutation = try self.model.structuralMutationCoordinator().beginStructuralMutation();
            defer mutation.deinit();
            const acc = self.accessor();
            if (try acc.getRoot()) |root_id| {
                var root_node = try acc.loadNode(root_id);
                defer acc.deinitNode(&root_node);
                return try self.removeIfFromNode(&root_node, null, qbox, predicate, ctx);
            }
            return 0;
        }

        pub fn visitNodes(self: *Self, comptime callback: anytype, ctx: anytype) Error!void {
            const acc = self.accessor();
            if (try acc.getRoot()) |root_id| {
                var root_node = try acc.loadNode(root_id);
                defer acc.deinitNode(&root_node);
                try self.visitNode(&root_node, callback, ctx);
            }
        }

        pub fn traverse(
            self: *const Self,
            comptime on_node: anytype,
            comptime on_entry: anytype,
            ctx: anytype,
        ) Error!void {
            const acc = self.accessor();
            if (try acc.getRoot()) |root_id| {
                var root_node = try acc.loadNode(root_id);
                defer acc.deinitNode(&root_node);
                try self.traverseNode(&root_node, on_node, on_entry, ctx);
            }
        }

        // -------------- helpers -------------- //
        pub fn childBounds(parent: *const Box, child_index: usize) Box {
            if (child_index >= child_count) {
                @panic("Child index out of bounds");
            }

            var low = parent.low;
            var high = parent.high;
            const center = parent.center();

            inline for (0..dimension) |axis| {
                const upper_half = (child_index & (1 << axis)) != 0;
                if (upper_half) {
                    low[axis] = center[axis];
                } else {
                    high[axis] = center[axis];
                }
            }

            return Box.create(low, high);
        }

        pub fn childIndexFor(parent: *const Box, child_box: *const Box) ?usize {
            if (!parent.containsBox(child_box)) {
                return null;
            }

            const center = parent.center();
            var child_index: usize = 0;

            inline for (0..dimension) |axis| {
                if (child_box.high[axis] <= center[axis]) {
                    // low half, do nothing
                } else if (child_box.low[axis] >= center[axis]) {
                    // high half
                    child_index |= 1 << axis;
                } else {
                    return null; // intersects center
                }
            }

            return child_index;
        }

        pub fn insertIntoNode(self: *Self, node: *Node, child_box: Box, value: Value) Error!void {
            var mutation = try self.model.structuralMutationCoordinator().beginStructuralMutation();
            defer mutation.deinit();
            return self.insertIntoNodeImpl(node, child_box, value);
        }

        fn insertIntoNodeImpl(self: *Self, node: *Node, child_box: Box, value: Value) Error!void {
            if (!node.isLeaf()) {
                const node_box = node.bounds();
                if (Self.childIndexFor(&node_box, &child_box)) |child_id| {
                    var next_node = try self.accessor().loadNode(node.getChild(child_id).?);
                    defer self.accessor().deinitNode(&next_node);
                    try self.insertIntoNodeImpl(&next_node, child_box, value);
                    try self.onInsert(node, child_box, value);
                    return;
                } else {
                    try node.addEntry(child_box, value);
                    try self.onInsert(node, child_box, value);
                }
                return;
            }
            if (!(try node.canInsertEntry(child_box, value)) and node.canSplit()) {
                const node_id = node.id();
                try self.splitNodeImpl(node);
                var split_node = try self.accessor().loadNode(node_id);
                defer self.accessor().deinitNode(&split_node);
                try self.insertIntoNodeImpl(&split_node, child_box, value);
                return;
            }
            try node.addEntry(child_box, value);
            try self.onInsert(node, child_box, value);
        }

        pub fn splitNode(self: *Self, node: *Node) Error!void {
            var mutation = try self.model.structuralMutationCoordinator().beginStructuralMutation();
            defer mutation.deinit();
            return self.splitNodeImpl(node);
        }

        fn splitNodeImpl(self: *Self, node: *Node) Error!void {
            try node.beforeSplit();
            const acc = self.accessor();
            const parent_id = node.id();
            const parent_bounds = node.bounds();
            var child_ids: [child_count]NodeId = undefined;

            inline for (0..child_count) |i| {
                const child_bounds = Self.childBounds(&parent_bounds, i);
                var child_node = try acc.createNode(child_bounds);
                defer acc.deinitNode(&child_node);
                child_ids[i] = child_node.id();
            }

            inline for (child_ids, 0..) |child_id, i| {
                try node.setChild(i, child_id);
                var child_node = try acc.loadNode(child_id);
                defer acc.deinitNode(&child_node);
                try child_node.setParent(parent_id);
                try child_node.setLevel(node.getLevel() + 1);
            }

            var entries = try node.entriesMut();
            defer entries.deinit();
            var cursor = try entries.cursor();
            defer cursor.deinit();

            while (try cursor.next()) |entry| {
                const entry_box = entry.box();
                if (Self.childIndexFor(&parent_bounds, &entry_box)) |child_index| {
                    var child_node = try acc.loadNode(child_ids[child_index]);
                    defer acc.deinitNode(&child_node);
                    var child_entries = try child_node.entriesMut();
                    defer child_entries.deinit();
                    const moved_entry = try entries.moveCurrentTo(&cursor, &child_entries);
                    try self.onAdopt(
                        node,
                        &child_node,
                        moved_entry.box(),
                        self.model.valueOutAsIn(moved_entry.value()),
                    );
                }
            }
        }

        pub fn growRootToContain(self: *Self, box: Box) Error!void {
            var mutation = try self.model.structuralMutationCoordinator().beginStructuralMutation();
            defer mutation.deinit();
            return self.growRootToContainImpl(box);
        }

        fn growRootToContainImpl(self: *Self, box: Box) Error!void {
            var acc = self.accessor();
            var current_root_id = (try acc.getRoot()) orelse return;

            var expanded_bounds = blk: {
                var root_node = try acc.loadNode(current_root_id);
                defer acc.deinitNode(&root_node);
                break :blk root_node.bounds();
            };

            while (!expanded_bounds.containsBox(&box)) {
                var low = expanded_bounds.low;
                var high = expanded_bounds.high;
                inline for (0..dimension) |axis| {
                    const extend = high[axis] - low[axis];
                    if (extend <= 0) {
                        return ErrorSet.InvalidId;
                    }
                    // A new root divides every axis in half. Expand every
                    // axis so the old root occupies exactly one child;
                    // expanding only the overflowing axis leaves it
                    // straddling the new root's center on the others.
                    if (box.low[axis] < low[axis]) {
                        low[axis] -= extend;
                    } else {
                        high[axis] += extend;
                    }
                }
                const grown_bounds = Box.create(low, high);

                var old_root_node = try acc.loadNode(current_root_id);
                defer acc.deinitNode(&old_root_node);

                const old_root_bounds = old_root_node.bounds();
                const old_root_child_id = Self.childIndexFor(
                    &grown_bounds,
                    &old_root_bounds,
                ) orelse
                    return ErrorSet.InvalidId;

                var new_root_node = try acc.createNode(grown_bounds);
                defer acc.deinitNode(&new_root_node);
                try new_root_node.beforeSplit();
                try new_root_node.setChild(old_root_child_id, current_root_id);
                inline for (0..child_count) |i| {
                    if (i != old_root_child_id) {
                        const child_bounds = Self.childBounds(&grown_bounds, i);
                        var child_node = try acc.createNode(child_bounds);
                        defer acc.deinitNode(&child_node);
                        try new_root_node.setChild(i, child_node.id());
                        try child_node.setParent(new_root_node.id());
                    }
                }

                try old_root_node.setParent(new_root_node.id());
                try acc.setRoot(new_root_node.id());
                try self.onGrow(&old_root_node, &new_root_node);

                current_root_id = new_root_node.id();
                expanded_bounds = new_root_node.bounds();
            }
        }

        pub fn queryNode(
            self: *const Self,
            node: *Node,
            qbox: Box,
            comptime callback: anytype,
            ctx: anytype,
        ) Error!void {
            if (!node.bounds().overlaps(&qbox)) {
                return;
            }

            var entries = try node.entries();
            defer entries.deinit();
            var eitr = try entries.iterator();
            defer eitr.deinit();

            while (try eitr.next()) |entry| {
                const entry_box = entry.box();
                if (entry_box.overlaps(&qbox)) {
                    try callback(ctx, entry_box, entry.value());
                }
            }

            if (node.isLeaf()) {
                return;
            }

            inline for (0..child_count) |i| {
                if (node.getChild(i)) |child_id| {
                    var child_node = try self.accessor().loadNode(child_id);
                    defer self.accessor().deinitNode(&child_node);
                    try self.queryNode(&child_node, qbox, callback, ctx);
                }
            }
        }

        fn queryEditableNode(
            self: *Self,
            node: *Node,
            qbox: Box,
            comptime callback: anytype,
            ctx: anytype,
        ) Error!void {
            if (!node.bounds().overlaps(&qbox)) {
                return;
            }

            var entries = try node.entriesMut();
            defer entries.deinit();
            var cursor = try entries.cursor();
            defer cursor.deinit();
            while (try cursor.next()) |entry| {
                const entry_box = entry.box();
                if (entry_box.overlaps(&qbox)) {
                    var hit = EditableQueryHit{
                        .tree = self,
                        .node = node,
                        .entries = &entries,
                        .cursor = &cursor,
                        .box = entry_box,
                    };
                    try callback(ctx, &hit);
                }
            }

            if (node.isLeaf()) {
                return;
            }
            inline for (0..child_count) |i| {
                if (node.getChild(i)) |child_id| {
                    var child_node = try self.accessor().loadNode(child_id);
                    defer self.accessor().deinitNode(&child_node);
                    try self.queryEditableNode(&child_node, qbox, callback, ctx);
                }
            }
        }

        pub fn visitNode(self: *Self, node: *Node, comptime callback: anytype, ctx: anytype) Error!void {
            switch (try callback(ctx, node.id(), node.bounds(), try node.traitMut())) {
                .skip_children => return,
                .descend => {},
            }

            if (node.isLeaf()) {
                return;
            }

            inline for (0..child_count) |i| {
                if (node.getChild(i)) |child_id| {
                    var child_node = try self.accessor().loadNode(child_id);
                    defer self.accessor().deinitNode(&child_node);
                    try self.visitNode(&child_node, callback, ctx);
                }
            }
        }

        fn traverseNode(
            self: *const Self,
            node: *Node,
            comptime on_node: anytype,
            comptime on_entry: anytype,
            ctx: anytype,
        ) Error!void {
            switch (try on_node(ctx, node.id(), node.bounds(), node.trait(), node.isLeaf())) {
                .accept => return,
                .skip => return,
                .descend => {},
            }

            var entries = try node.entries();
            defer entries.deinit();
            var eitr = try entries.iterator();
            defer eitr.deinit();

            while (try eitr.next()) |entry| {
                try on_entry(ctx, entry.box(), entry.value());
            }

            if (node.isLeaf()) {
                return;
            }

            inline for (0..child_count) |i| {
                if (node.getChild(i)) |child_id| {
                    var child_node = try self.accessor().loadNode(child_id);
                    defer self.accessor().deinitNode(&child_node);
                    try self.traverseNode(
                        &child_node,
                        on_node,
                        on_entry,
                        ctx,
                    );
                }
            }
        }

        const RemoveResult = struct {
            bbox: Box,
            value: ValueBorrow,
        };

        const NodePath = struct {
            node: *Node,
            parent: ?*const @This(),

            fn onRemove(self: *const @This(), tree: *Self, box: Box, value: Value) Error!void {
                var current: ?*const @This() = self;
                while (current) |path| {
                    try tree.onRemove(path.node, box, value);
                    current = path.parent;
                }
            }
        };

        fn removeIfFromNode(
            self: *Self,
            node: *Node,
            parent_path: ?*const NodePath,
            qbox: Box,
            comptime predicate: anytype,
            ctx: anytype,
        ) Error!usize {
            if (!node.bounds().overlaps(&qbox)) {
                return 0;
            }

            const path = NodePath{ .node = node, .parent = parent_path };
            var entries = try node.entriesMut();
            defer entries.deinit();
            var cursor = try entries.cursor();
            defer cursor.deinit();

            var removed_total: usize = 0;
            while (try cursor.next()) |entry| {
                const entry_box = entry.box();
                if (!entry_box.overlaps(&qbox)) {
                    continue;
                }
                const entry_value = self.model.valueOutAsIn(entry.value());
                if (!try predicate(ctx, entry_box, entry_value)) {
                    continue;
                }

                try entries.markCurrentTombstone(&cursor);
                try path.onRemove(self, entry_box, entry_value);
                try self.model.decrementEntriesCount();
                removed_total += 1;
            }

            if (node.isLeaf()) {
                return removed_total;
            }
            inline for (0..child_count) |i| {
                if (node.getChild(i)) |child_id| {
                    var child_node = try self.accessor().loadNode(child_id);
                    defer self.accessor().deinitNode(&child_node);
                    removed_total += try self.removeIfFromNode(
                        &child_node,
                        &path,
                        qbox,
                        predicate,
                        ctx,
                    );
                }
            }
            return removed_total;
        }

        fn removeFromNode(
            self: *Self,
            node: *Node,
            qbox: Box,
            comptime callback: anytype,
            ctx: anytype,
        ) Error!?RemoveResult {
            if (!node.bounds().overlaps(&qbox)) {
                return null;
            }
            var entries = try node.entriesMut();
            defer entries.deinit();
            var cursor = try entries.cursor();
            defer cursor.deinit();
            while (try cursor.next()) |entry| {
                const entry_box = entry.box();
                if (entry_box.overlaps(&qbox)) {
                    if (try callback(ctx, entry_box, entry.value())) {
                        var removed_value = try entries.removeCurrent(&cursor);
                        errdefer self.model.deinitBorrowValue(&removed_value);
                        self.model.decrementEntriesCount() catch |err| {
                            try self.model.finalizeBorrowValue(&removed_value);
                            return err;
                        };
                        self.onRemove(
                            node,
                            entry_box,
                            self.model.valueBorrowAsIn(&removed_value),
                        ) catch |err| {
                            try self.model.finalizeBorrowValue(&removed_value);
                            return err;
                        };
                        return RemoveResult{
                            .bbox = entry_box,
                            .value = removed_value,
                        };
                    }
                }
            }

            if (node.isLeaf()) {
                return null;
            }

            inline for (0..child_count) |i| {
                if (node.getChild(i)) |child_id| {
                    var child_node = try self.accessor().loadNode(child_id);
                    defer self.accessor().deinitNode(&child_node);
                    if (try self.removeFromNode(&child_node, qbox, callback, ctx)) |result_const| {
                        var result = result_const;
                        errdefer self.model.deinitBorrowValue(&result.value);
                        self.onRemove(
                            node,
                            result.bbox,
                            self.model.valueBorrowAsIn(&result.value),
                        ) catch |err| {
                            try self.model.finalizeBorrowValue(&result.value);
                            return err;
                        };
                        return result;
                    }
                }
            }
            return null;
        }

        fn onInsert(self: *Self, node: *Node, box: Box, value: Value) Error!void {
            if (@hasDecl(Model, "onInsert")) {
                try self.model.onInsert(node, box, value);
            }
        }

        fn onAdopt(self: *Self, src: *Node, target: *Node, box: Box, value: Value) Error!void {
            if (@hasDecl(Model, "onAdopt")) {
                try self.model.onAdopt(src, target, box, value);
            }
        }

        fn onRemove(self: *Self, node: *Node, box: Box, value: Value) Error!void {
            if (@hasDecl(Model, "onRemove")) {
                try self.model.onRemove(node, box, value);
            }
        }

        fn updateTraitsAlongPath(
            self: *Self,
            start_id: NodeId,
            box: Box,
            old_value: Value,
            new_value: Value,
        ) Error!void {
            var current_id: ?NodeId = start_id;
            while (current_id) |node_id| {
                var node = try self.accessor().loadNode(node_id);
                defer self.accessor().deinitNode(&node);
                const parent_id = try node.getParent();
                self.model.onUpdate(&node, box, old_value, new_value) catch |err| {
                    self.rollbackTraitUpdates(start_id, node_id, box, new_value, old_value);
                    return err;
                };
                current_id = parent_id;
            }
        }

        fn rollbackTraitUpdates(
            self: *Self,
            start_id: NodeId,
            failed_id: NodeId,
            box: Box,
            old_value: Value,
            new_value: Value,
        ) void {
            var current_id: ?NodeId = start_id;
            while (current_id) |node_id| {
                if (std.meta.eql(node_id, failed_id)) {
                    return;
                }
                var node = self.accessor().loadNode(node_id) catch {
                    @panic("OrthTree trait update rollback could not load a node");
                };
                defer self.accessor().deinitNode(&node);
                const parent_id = node.getParent() catch {
                    @panic("OrthTree trait update rollback could not load a parent");
                };
                self.model.onUpdate(&node, box, old_value, new_value) catch {
                    @panic("OrthTree trait update rollback failed");
                };
                current_id = parent_id;
            }
        }

        fn onGrow(self: *Self, node: *Node, new_root: *Node) Error!void {
            if (@hasDecl(Model, "onGrow")) {
                try self.model.onGrow(node, new_root);
            }
        }
    };
}
