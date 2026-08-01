const std = @import("std");
const fulla = @import("fullaz");
const orthtree = fulla.spatial.orthtree;

fn MassTrait(comptime Coord: type, comptime dimension: usize, comptime Value: type) type {
    _ = Coord;
    _ = dimension;

    return struct {
        const Self = @This();
        pub const Error = error{};

        mass: Value = 0,
        visits: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn onInsert(self: *Self, box: anytype, value: Value) Error!void {
            _ = box;
            self.mass += value;
        }

        pub fn onGrow(self: *Self, old: *const Self) Error!void {
            self.mass = old.mass;
        }

        pub fn onAdopt(self: *Self, box: anytype, value: Value) Error!void {
            _ = box;
            self.mass += value;
        }

        pub fn onRemove(self: *Self, box: anytype, value: Value) Error!void {
            _ = box;
            self.mass -= value;
        }
    };
}

fn FailingRemoveTrait(comptime Coord: type, comptime dimension: usize, comptime Value: type) type {
    _ = Coord;
    _ = dimension;

    return struct {
        const Self = @This();
        pub const Error = error{RemoveFailed};

        pub fn init() Self {
            return .{};
        }

        pub fn onInsert(_: *Self, _: anytype, _: Value) Error!void {}
        pub fn onGrow(_: *Self, _: *const Self) Error!void {}
        pub fn onAdopt(_: *Self, _: anytype, _: Value) Error!void {}
        pub fn onRemove(_: *Self, _: anytype, _: Value) Error!void {
            return error.RemoveFailed;
        }
    };
}

fn expectChildBounds(comptime Coord: type) !void {
    const Model = orthtree.models.Memory(Coord, 2, u32);
    const TreeType = orthtree.tree.TreeImpl(Model);
    const Box = Model.Box;

    const parent = Box.create(.{ 0, 0 }, .{ 10, 10 });
    const expected = [_]Box{
        Box.create(.{ 0, 0 }, .{ 5, 5 }),
        Box.create(.{ 5, 0 }, .{ 10, 5 }),
        Box.create(.{ 0, 5 }, .{ 5, 10 }),
        Box.create(.{ 5, 5 }, .{ 10, 10 }),
    };

    inline for (expected, 0..) |expected_bounds, i| {
        try std.testing.expect(std.meta.eql(expected_bounds, TreeType.childBounds(&parent, i)));
    }
}

fn expectChildIndexFor(comptime Coord: type) !void {
    const Model = orthtree.models.Memory(Coord, 2, u32);
    const TreeType = orthtree.tree.TreeImpl(Model);
    const Box = Model.Box;

    const parent = Box.create(.{ 0, 0 }, .{ 10, 10 });
    inline for (0..TreeType.child_count) |i| {
        const child_bounds = TreeType.childBounds(&parent, i);
        try std.testing.expectEqual(i, TreeType.childIndexFor(&parent, &child_bounds).?);
    }

    const crosses_x = Box.create(.{ 4, 1 }, .{ 6, 4 });
    const crosses_y = Box.create(.{ 1, 4 }, .{ 4, 6 });
    const outside_parent = Box.create(.{ 9, 1 }, .{ 11, 4 });
    try std.testing.expect(TreeType.childIndexFor(&parent, &crosses_x) == null);
    try std.testing.expect(TreeType.childIndexFor(&parent, &crosses_y) == null);
    try std.testing.expect(TreeType.childIndexFor(&parent, &outside_parent) == null);
}

fn expectSplitNode(comptime Coord: type) !void {
    const Model = orthtree.models.Memory(Coord, 2, u32);
    const TreeType = orthtree.tree.TreeImpl(Model);
    const Box = Model.Box;

    var model = try Model.init(std.testing.allocator, 8);
    defer model.deinit();

    var tree = TreeType.init(&model);
    const acc = model.getAccessor();
    var node = try acc.createNode(Box.create(.{ 0, 0 }, .{ 10, 10 }));
    const parent_id = node.id();
    const parent_bounds = node.bounds();
    const entries = [_]Box{
        Box.create(.{ 1, 1 }, .{ 2, 2 }),
        Box.create(.{ 6, 1 }, .{ 7, 2 }),
        Box.create(.{ 1, 6 }, .{ 2, 7 }),
        Box.create(.{ 6, 6 }, .{ 7, 7 }),
        Box.create(.{ 4, 1 }, .{ 6, 2 }),
    };

    inline for (entries, 0..) |entry_box, i| {
        _ = i;
        try node.addEntry(entry_box, 0);
    }
    try tree.splitNode(&node);

    var parent = try acc.loadNode(parent_id);
    defer acc.deinitNode(&parent);
    try std.testing.expect(!parent.isLeaf());
    try std.testing.expectEqual(@as(usize, 1), parent.size());
    try std.testing.expect(std.meta.eql(entries[4], (try parent.getEntry(0)).box()));

    inline for (0..TreeType.child_count) |i| {
        const child_id = parent.getChild(i).?;
        var child = try acc.loadNode(child_id);
        defer acc.deinitNode(&child);

        try std.testing.expect(child.isLeaf());
        try std.testing.expectEqual(parent_id, (try child.getParent()).?);
        try std.testing.expect(std.meta.eql(TreeType.childBounds(&parent_bounds, i), child.bounds()));
        try std.testing.expectEqual(@as(usize, 1), child.size());
        try std.testing.expect(std.meta.eql(entries[i], (try child.getEntry(0)).box()));
    }
}

fn expectSplitAdoptsEntries(comptime Coord: type) !void {
    const Model = orthtree.models.MemoryImpl(Coord, 2, u32, MassTrait);
    const TreeType = orthtree.tree.TreeImpl(Model);
    const Box = Model.Box;

    var model = try Model.init(std.testing.allocator, 8);
    defer model.deinit();

    var tree = TreeType.init(&model);
    const acc = model.getAccessor();
    var parent = try acc.createNode(Box.create(.{ 0, 0 }, .{ 10, 10 }));
    defer acc.deinitNode(&parent);
    const entries = [_]Box{
        Box.create(.{ 1, 1 }, .{ 2, 2 }),
        Box.create(.{ 6, 1 }, .{ 7, 2 }),
        Box.create(.{ 1, 6 }, .{ 2, 7 }),
        Box.create(.{ 6, 6 }, .{ 7, 7 }),
    };

    inline for (entries, 0..) |entry_box, i| {
        const value: u32 = @intCast(i + 1);
        try parent.addEntry(entry_box, value);
        try model.onInsert(&parent, entry_box, value);
    }
    try tree.splitNode(&parent);

    try std.testing.expectEqual(@as(u32, 10), parent.getTrait().mass);
    try std.testing.expectEqual(@as(usize, 0), parent.size());
    inline for (0..TreeType.child_count) |i| {
        var child = try acc.loadNode(parent.getChild(i).?);
        defer acc.deinitNode(&child);
        try std.testing.expectEqual(@as(u32, @intCast(i + 1)), child.getTrait().mass);
        try std.testing.expectEqual(@as(usize, 1), child.size());
    }
}

fn expectInsert(comptime Coord: type) !void {
    const Model = orthtree.models.Memory(Coord, 2, u32);
    const TreeType = orthtree.tree.TreeImpl(Model);
    const Box = Model.Box;

    var model = try Model.init(std.testing.allocator, 1);
    defer model.deinit();

    var tree = TreeType.init(&model);
    const acc = model.getAccessor();
    const first = Box.create(.{ 0, 0 }, .{ 10, 10 });
    const second = Box.create(.{ 1, 1 }, .{ 2, 2 });

    try tree.insert(first, 1);
    try tree.insert(second, 2);

    const root_id = acc.getRoot().?;
    var root = try acc.loadNode(root_id);
    defer acc.deinitNode(&root);
    try std.testing.expect(!root.isLeaf());
    try std.testing.expectEqual(@as(usize, 1), root.size());
    try std.testing.expect(std.meta.eql(first, (try root.getEntry(0)).box()));

    const child_id = root.getChild(0).?;
    var child = try acc.loadNode(child_id);
    defer acc.deinitNode(&child);
    try std.testing.expectEqual(root_id, (try child.getParent()).?);
    try std.testing.expectEqual(@as(usize, 1), child.size());
    try std.testing.expect(std.meta.eql(second, (try child.getEntry(0)).box()));
}

fn expectInsertGrowsRoot(comptime Coord: type) !void {
    const Model = orthtree.models.Memory(Coord, 2, u32);
    const TreeType = orthtree.tree.TreeImpl(Model);
    const Box = Model.Box;

    var model = try Model.init(std.testing.allocator, 8);
    defer model.deinit();

    var tree = TreeType.init(&model);
    const acc = model.getAccessor();
    const first = Box.create(.{ 0, 0 }, .{ 2, 2 });
    const second = Box.create(.{ 3, 3 }, .{ 4, 4 });

    try tree.insert(first, 1);
    try tree.insert(second, 2);

    const root_id = acc.getRoot().?;
    var root = try acc.loadNode(root_id);
    defer acc.deinitNode(&root);
    try std.testing.expect(std.meta.eql(Box.create(.{ 0, 0 }, .{ 4, 4 }), root.bounds()));
    try std.testing.expectEqual(@as(usize, 0), root.size());

    const old_root_id = root.getChild(0).?;
    var old_root = try acc.loadNode(old_root_id);
    defer acc.deinitNode(&old_root);
    try std.testing.expectEqual(root_id, (try old_root.getParent()).?);
    try std.testing.expectEqual(@as(usize, 1), old_root.size());
    try std.testing.expect(std.meta.eql(first, (try old_root.getEntry(0)).box()));

    var new_entry_child = try acc.loadNode(root.getChild(3).?);
    defer acc.deinitNode(&new_entry_child);
    try std.testing.expectEqual(@as(usize, 1), new_entry_child.size());
    try std.testing.expect(std.meta.eql(second, (try new_entry_child.getEntry(0)).box()));
}

fn expectInsertGrowsRootAlongSingleAxis(comptime Coord: type) !void {
    const Model = orthtree.models.Memory(Coord, 2, u32);
    const TreeType = orthtree.tree.TreeImpl(Model);
    const Box = Model.Box;

    var model = try Model.init(std.testing.allocator, 8);
    defer model.deinit();

    var tree = TreeType.init(&model);
    const acc = model.getAccessor();
    try tree.insert(Box.create(.{ 0, 0 }, .{ 2, 2 }), 1);
    try tree.insert(Box.create(.{ 3, 1 }, .{ 4, 2 }), 2);

    var root = try acc.loadNode(acc.getRoot().?);
    defer acc.deinitNode(&root);
    try std.testing.expect(std.meta.eql(Box.create(.{ 0, 0 }, .{ 4, 4 }), root.bounds()));

    try std.testing.expectEqual(@as(usize, 2), try model.getEntriesCount());
}

fn expectQuery(comptime Coord: type) !void {
    const Model = orthtree.models.Memory(Coord, 2, u32);
    const TreeType = orthtree.tree.TreeImpl(Model);
    const Box = Model.Box;
    const QueryContext = struct {
        values: [3]u32 = undefined,
        len: usize = 0,

        fn callback(ctx: *@This(), entry_box: Box, value: u32) !void {
            _ = entry_box;
            ctx.values[ctx.len] = value;
            ctx.len += 1;
        }

        fn contains(ctx: *const @This(), value: u32) bool {
            for (ctx.values[0..ctx.len]) |result| {
                if (result == value) {
                    return true;
                }
            }
            return false;
        }
    };

    var model = try Model.init(std.testing.allocator, 1);
    defer model.deinit();

    var tree = TreeType.init(&model);
    try tree.insert(Box.create(.{ 0, 0 }, .{ 10, 10 }), 1);
    try tree.insert(Box.create(.{ 1, 1 }, .{ 2, 2 }), 2);
    try tree.insert(Box.create(.{ 6, 6 }, .{ 7, 7 }), 3);

    var lower_results = QueryContext{};
    try tree.query(Box.create(.{ 0, 0 }, .{ 3, 3 }), QueryContext.callback, &lower_results);
    try std.testing.expectEqual(@as(usize, 2), lower_results.len);
    try std.testing.expect(lower_results.contains(1));
    try std.testing.expect(lower_results.contains(2));

    var upper_results = QueryContext{};
    try tree.query(Box.create(.{ 5, 5 }, .{ 8, 8 }), QueryContext.callback, &upper_results);
    try std.testing.expectEqual(@as(usize, 2), upper_results.len);
    try std.testing.expect(upper_results.contains(1));
    try std.testing.expect(upper_results.contains(3));

    var empty_results = QueryContext{};
    try tree.query(Box.create(.{ 11, 11 }, .{ 12, 12 }), QueryContext.callback, &empty_results);
    try std.testing.expectEqual(@as(usize, 0), empty_results.len);
}

fn expectInsertHooks(comptime Coord: type) !void {
    const Model = orthtree.models.MemoryImpl(Coord, 2, u32, MassTrait);
    const TreeType = orthtree.tree.TreeImpl(Model);
    const Box = Model.Box;

    var model = try Model.init(std.testing.allocator, 1);
    defer model.deinit();

    var tree = TreeType.init(&model);
    const acc = model.getAccessor();
    try tree.insert(Box.create(.{ 0, 0 }, .{ 10, 10 }), 5);
    try tree.insert(Box.create(.{ 1, 1 }, .{ 2, 2 }), 7);

    var root = try acc.loadNode(acc.getRoot().?);
    defer acc.deinitNode(&root);
    try std.testing.expectEqual(@as(u32, 12), root.getTrait().mass);

    var child = try acc.loadNode(root.getChild(0).?);
    defer acc.deinitNode(&child);
    try std.testing.expectEqual(@as(u32, 7), child.getTrait().mass);

    var growth_model = try Model.init(std.testing.allocator, 8);
    defer growth_model.deinit();

    var growth_tree = TreeType.init(&growth_model);
    const growth_acc = growth_model.getAccessor();
    try growth_tree.insert(Box.create(.{ 0, 0 }, .{ 2, 2 }), 5);
    try growth_tree.insert(Box.create(.{ 3, 3 }, .{ 4, 4 }), 7);

    var grown_root = try growth_acc.loadNode(growth_acc.getRoot().?);
    defer growth_acc.deinitNode(&grown_root);
    try std.testing.expectEqual(@as(u32, 12), grown_root.getTrait().mass);

    var old_root = try growth_acc.loadNode(grown_root.getChild(0).?);
    defer growth_acc.deinitNode(&old_root);
    try std.testing.expectEqual(@as(u32, 5), old_root.getTrait().mass);
}

fn expectVisitNodes(comptime Coord: type) !void {
    const Model = orthtree.models.MemoryImpl(Coord, 2, u32, MassTrait);
    const TreeType = orthtree.tree.TreeImpl(Model);
    const Box = Model.Box;
    const Trait = MassTrait(Coord, 2, u32);
    const VisitContext = struct {
        root_bounds: Box,
        count: usize = 0,
        mass_sum: u32 = 0,
        saw_root: bool = false,

        fn visit(ctx: *@This(), _: usize, bounds: Box, trait: *Trait) !orthtree.tree.VisitorResult {
            ctx.count += 1;
            ctx.mass_sum += trait.mass;
            trait.visits += 1;
            if (std.meta.eql(bounds, ctx.root_bounds)) {
                ctx.saw_root = true;
            }
            return .descend;
        }

        fn skip(ctx: *@This(), _: usize, _: Box, _: *Trait) !orthtree.tree.VisitorResult {
            ctx.count += 1;
            return .skip_children;
        }
    };

    var empty_model = try Model.init(std.testing.allocator, 8);
    defer empty_model.deinit();
    var empty_tree = TreeType.init(&empty_model);
    var empty_visit = VisitContext{ .root_bounds = Box.create(.{ 0, 0 }, .{ 0, 0 }) };
    try empty_tree.visitNodes(VisitContext.visit, &empty_visit);
    try std.testing.expectEqual(@as(usize, 0), empty_visit.count);

    var model = try Model.init(std.testing.allocator, 8);
    defer model.deinit();

    var tree = TreeType.init(&model);
    const acc = model.getAccessor();
    try tree.insert(Box.create(.{ 0, 0 }, .{ 2, 2 }), 5);
    try tree.insert(Box.create(.{ 3, 3 }, .{ 4, 4 }), 7);

    const root_bounds = Box.create(.{ 0, 0 }, .{ 4, 4 });
    var visit = VisitContext{ .root_bounds = root_bounds };
    try tree.visitNodes(VisitContext.visit, &visit);
    try std.testing.expectEqual(@as(usize, 5), visit.count);
    try std.testing.expectEqual(@as(u32, 24), visit.mass_sum);
    try std.testing.expect(visit.saw_root);

    var root = try acc.loadNode(acc.getRoot().?);
    defer acc.deinitNode(&root);
    try std.testing.expect(std.meta.eql(root_bounds, root.bounds()));
    try std.testing.expectEqual(@as(usize, 1), root.getTrait().visits);
    inline for (0..TreeType.child_count) |i| {
        var child = try acc.loadNode(root.getChild(i).?);
        defer acc.deinitNode(&child);
        try std.testing.expect(std.meta.eql(TreeType.childBounds(&root_bounds, i), child.bounds()));
        try std.testing.expectEqual(@as(usize, 1), child.getTrait().visits);
    }

    var prune_visit = VisitContext{ .root_bounds = root_bounds };
    try tree.visitNodes(VisitContext.skip, &prune_visit);
    try std.testing.expectEqual(@as(usize, 1), prune_visit.count);
}

fn expectTraverse(comptime Coord: type) !void {
    const Model = orthtree.models.MemoryImpl(Coord, 2, u32, MassTrait);
    const TreeType = orthtree.tree.TreeImpl(Model);
    const Box = Model.Box;
    const Trait = MassTrait(Coord, 2, u32);
    const TraverseContext = struct {
        accept_root: bool = false,
        skip_root: bool = false,
        node_count: usize = 0,
        entry_count: usize = 0,
        accepted_mass: u32 = 0,
        entry_mass: u32 = 0,

        fn onNode(
            ctx: *@This(),
            _: usize,
            _: Box,
            trait: *const Trait,
            _: bool,
        ) !orthtree.tree.TraverseDecision {
            ctx.node_count += 1;
            if (ctx.accept_root) {
                ctx.accepted_mass += trait.mass;
                return .accept;
            }
            if (ctx.skip_root) {
                return .skip;
            }
            return .descend;
        }

        fn onEntry(ctx: *@This(), _: Box, value: u32) !void {
            ctx.entry_count += 1;
            ctx.entry_mass += value;
        }
    };

    var empty_model = try Model.init(std.testing.allocator, 1);
    defer empty_model.deinit();
    var empty_tree = TreeType.init(&empty_model);
    var empty = TraverseContext{};
    try empty_tree.traverse(TraverseContext.onNode, TraverseContext.onEntry, &empty);
    try std.testing.expectEqual(@as(usize, 0), empty.node_count);
    try std.testing.expectEqual(@as(usize, 0), empty.entry_count);

    var model = try Model.init(std.testing.allocator, 1);
    defer model.deinit();

    var tree = TreeType.init(&model);
    try tree.initRootBounds(Box.create(.{ 0, 0 }, .{ 4, 4 }));
    try tree.insert(Box.create(.{ 0, 0 }, .{ 1, 1 }), 5);
    try tree.insert(Box.create(.{ 3, 3 }, .{ 4, 4 }), 7);

    var accepted = TraverseContext{ .accept_root = true };
    try tree.traverse(TraverseContext.onNode, TraverseContext.onEntry, &accepted);
    try std.testing.expectEqual(@as(usize, 1), accepted.node_count);
    try std.testing.expectEqual(@as(u32, 12), accepted.accepted_mass);
    try std.testing.expectEqual(@as(usize, 0), accepted.entry_count);
    try std.testing.expectEqual(@as(u32, 0), accepted.entry_mass);

    var descended = TraverseContext{};
    try tree.traverse(TraverseContext.onNode, TraverseContext.onEntry, &descended);
    try std.testing.expectEqual(@as(usize, 5), descended.node_count);
    try std.testing.expectEqual(@as(usize, 2), descended.entry_count);
    try std.testing.expectEqual(@as(u32, 12), descended.entry_mass);

    var skipped = TraverseContext{ .skip_root = true };
    try tree.traverse(TraverseContext.onNode, TraverseContext.onEntry, &skipped);
    try std.testing.expectEqual(@as(usize, 1), skipped.node_count);
    try std.testing.expectEqual(@as(usize, 0), skipped.entry_count);
    try std.testing.expectEqual(@as(u32, 0), skipped.entry_mass);
}

fn expectEntryCursor(comptime Coord: type) !void {
    const Model = orthtree.models.Memory(Coord, 2, u32);
    const Box = Model.Box;

    var model = try Model.init(std.testing.allocator, 8);
    defer model.deinit();

    const acc = model.getAccessor();
    var source = try acc.createNode(Box.create(.{ 0, 0 }, .{ 10, 10 }));
    defer acc.deinitNode(&source);
    var target = try acc.createNode(Box.create(.{ 0, 0 }, .{ 10, 10 }));
    defer acc.deinitNode(&target);

    try source.addEntry(Box.create(.{ 1, 1 }, .{ 2, 2 }), 1);
    try source.addEntry(Box.create(.{ 3, 3 }, .{ 4, 4 }), 2);
    try source.addEntry(Box.create(.{ 5, 5 }, .{ 6, 6 }), 3);

    var source_entries = try source.entriesMut();
    defer source.deinitEntries(&source_entries);
    var cursor = source_entries.cursor();
    defer cursor.deinit();

    try std.testing.expectEqual(@as(u32, 1), cursor.next().?.value());
    try std.testing.expectEqual(@as(u32, 1), try source_entries.removeCurrent(&cursor));

    try std.testing.expectEqual(@as(u32, 2), cursor.next().?.value());
    var target_entries = try target.entriesMut();
    defer target.deinitEntries(&target_entries);
    const moved = try source_entries.moveCurrentTo(&cursor, &target_entries);
    try std.testing.expectEqual(@as(u32, 2), moved.value());

    try std.testing.expectEqual(@as(u32, 3), cursor.next().?.value());
    try std.testing.expect(cursor.next() == null);
    try std.testing.expectEqual(@as(usize, 1), source.size());
    try std.testing.expectEqual(@as(usize, 1), target.size());
    try std.testing.expectEqual(@as(u32, 3), (try source.getEntry(0)).value());
    try std.testing.expectEqual(@as(u32, 2), (try target.getEntry(0)).value());
}

fn expectRemove(comptime Coord: type) !void {
    const Model = orthtree.models.MemoryImpl(Coord, 2, u32, MassTrait);
    const TreeType = orthtree.tree.TreeImpl(Model);
    const Box = Model.Box;
    const RemoveContext = struct {
        target: TreeType.ValueBorrow,
        calls: usize = 0,

        fn predicate(ctx: *@This(), _: Box, value: TreeType.ValueBorrow) !bool {
            ctx.calls += 1;
            return value == ctx.target;
        }
    };
    const QueryContext = struct {
        values: [2]u32 = undefined,
        len: usize = 0,

        fn collect(ctx: *@This(), _: Box, value: TreeType.ValueBorrow) !void {
            ctx.values[ctx.len] = value;
            ctx.len += 1;
        }
    };

    var model = try Model.init(std.testing.allocator, 1);
    defer model.deinit();

    var tree = TreeType.init(&model);
    const acc = model.getAccessor();
    try tree.insert(Box.create(.{ 0, 0 }, .{ 10, 10 }), 5);
    try tree.insert(Box.create(.{ 1, 1 }, .{ 2, 2 }), 7);
    try tree.insert(Box.create(.{ 6, 6 }, .{ 7, 7 }), 11);

    var remove_ctx = RemoveContext{ .target = 7 };
    const removed = try tree.remove(
        Box.create(.{ 0, 0 }, .{ 3, 3 }),
        RemoveContext.predicate,
        &remove_ctx,
    );
    try std.testing.expect(removed);
    try std.testing.expect(remove_ctx.calls >= 2);
    try std.testing.expectEqual(@as(usize, 2), try model.getEntriesCount());

    var root = try acc.loadNode(acc.getRoot().?);
    defer acc.deinitNode(&root);
    try std.testing.expectEqual(@as(u32, 16), root.getTrait().mass);

    var child = try acc.loadNode(root.getChild(0).?);
    defer acc.deinitNode(&child);
    try std.testing.expectEqual(@as(usize, 0), child.size());
    try std.testing.expectEqual(@as(u32, 0), child.getTrait().mass);

    var query_ctx = QueryContext{};
    try tree.query(Box.create(.{ 0, 0 }, .{ 10, 10 }), QueryContext.collect, &query_ctx);
    try std.testing.expectEqual(@as(usize, 2), query_ctx.len);
    try std.testing.expect(query_ctx.values[0] == 5 or query_ctx.values[1] == 5);
    try std.testing.expect(query_ctx.values[0] == 11 or query_ctx.values[1] == 11);

    var missing_ctx = RemoveContext{ .target = 99 };
    const missing = try tree.remove(
        Box.create(.{ 0, 0 }, .{ 10, 10 }),
        RemoveContext.predicate,
        &missing_ctx,
    );
    try std.testing.expect(!missing);
    try std.testing.expectEqual(@as(usize, 2), try model.getEntriesCount());
}

fn expectRemoveHookError(comptime Coord: type) !void {
    const Model = orthtree.models.MemoryImpl(Coord, 2, u32, FailingRemoveTrait);
    const TreeType = orthtree.tree.TreeImpl(Model);
    const Box = Model.Box;
    const RemoveContext = struct {
        fn predicate(_: *@This(), _: Box, _: u32) !bool {
            return true;
        }
    };

    var model = try Model.init(std.testing.allocator, 8);
    defer model.deinit();
    var tree = TreeType.init(&model);
    try tree.insert(Box.create(.{ 0, 0 }, .{ 1, 1 }), 1);

    var context = RemoveContext{};
    try std.testing.expectError(
        error.RemoveFailed,
        tree.remove(Box.create(.{ 0, 0 }, .{ 1, 1 }), RemoveContext.predicate, &context),
    );
    try std.testing.expectEqual(@as(usize, 0), try model.getEntriesCount());

    const acc = model.getAccessor();
    var root = try acc.loadNode(acc.getRoot().?);
    defer acc.deinitNode(&root);
    try std.testing.expectEqual(@as(usize, 0), root.size());
}

test "OrthTree: create" {
    _ = fulla.spatial.orthtree;
}

test "OrthTree: memory model" {
    const Model = orthtree.models.Memory(u32, 2, u32);
    const TreeType = orthtree.tree.TreeImpl(Model);
    const Box = Model.Box;

    const allocator = std.testing.allocator;

    var model = try Model.init(allocator, 8);
    defer model.deinit();

    const tree = TreeType.init(&model);

    _ = tree;
    const acc = model.getAccessor();
    const node = try acc.createNode(Box.create(
        .{ 0, 0 },
        .{ 10, 10 },
    ));
    _ = node;
}

test "OrthTree: child bounds for u32" {
    try expectChildBounds(u32);
}

test "OrthTree: child bounds for f32" {
    try expectChildBounds(f32);
}

test "OrthTree: child index for u32" {
    try expectChildIndexFor(u32);
}

test "OrthTree: child index for f32" {
    try expectChildIndexFor(f32);
}

test "OrthTree: split node for u32" {
    try expectSplitNode(u32);
}

test "OrthTree: split node for f32" {
    try expectSplitNode(f32);
}

test "OrthTree: split adopts entries for u32 coordinates" {
    try expectSplitAdoptsEntries(u32);
}

test "OrthTree: split adopts entries for f32 coordinates" {
    try expectSplitAdoptsEntries(f32);
}

test "OrthTree: insert for u32" {
    try expectInsert(u32);
}

test "OrthTree: insert for f32" {
    try expectInsert(f32);
}

test "OrthTree: insert grows root for u32" {
    try expectInsertGrowsRoot(u32);
}

test "OrthTree: insert grows root for f32" {
    try expectInsertGrowsRoot(f32);
}

test "OrthTree: insert grows root along one axis for u32" {
    try expectInsertGrowsRootAlongSingleAxis(u32);
}

test "OrthTree: insert grows root along one axis for f32" {
    try expectInsertGrowsRootAlongSingleAxis(f32);
}

test "OrthTree: query for u32" {
    try expectQuery(u32);
}

test "OrthTree: query for f32" {
    try expectQuery(f32);
}

test "OrthTree: insert hooks for u32 coordinates" {
    try expectInsertHooks(u32);
}

test "OrthTree: insert hooks for f32 coordinates" {
    try expectInsertHooks(f32);
}

test "OrthTree: visit nodes for u32 coordinates" {
    try expectVisitNodes(u32);
}

test "OrthTree: visit nodes for f32 coordinates" {
    try expectVisitNodes(f32);
}

test "OrthTree: traverse for u32 coordinates" {
    try expectTraverse(u32);
}

test "OrthTree: traverse for f32 coordinates" {
    try expectTraverse(f32);
}

test "OrthTree: entry cursor for u32 coordinates" {
    try expectEntryCursor(u32);
}

test "OrthTree: entry cursor for f32 coordinates" {
    try expectEntryCursor(f32);
}

test "OrthTree: remove for u32 coordinates" {
    try expectRemove(u32);
}

test "OrthTree: remove for f32 coordinates" {
    try expectRemove(f32);
}

test "OrthTree: remove hook error for u32 coordinates" {
    try expectRemoveHookError(u32);
}

test "OrthTree: remove hook error for f32 coordinates" {
    try expectRemoveHookError(f32);
}
