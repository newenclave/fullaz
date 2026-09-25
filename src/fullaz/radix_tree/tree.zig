const std = @import("std");
const KeySplitter = @import("splitter.zig").Splitter;
const errors = @import("../core/errors.zig");
const StructuralMutationCoordinator = @import("../core/core.zig").structural_mutation.StructuralMutationCoordinator;
const StructuralMutationError = @import("../core/core.zig").structural_mutation.Error;
const model_interfaces = @import("models/interfaces.zig");

pub fn Tree(comptime ModelT: type) type {
    comptime model_interfaces.assertModel(ModelT);

    const Model = ModelT;
    const LeafType = Model.LeafType;

    const KeyInType = Model.KeyInType;
    const ValueInType = Model.ValueInType;
    const ValueOutType = Model.ValueOutType;
    const NodeIdType = Model.NodeIdType;

    const SplitKeyType = Model.SplitKeyType;

    return struct {
        const Self = @This();

        const Splitter = KeySplitter(KeyInType);
        pub const Error = Splitter.Error ||
            Model.Error ||
            errors.HandleError ||
            errors.LayoutError ||
            StructuralMutationError;
        pub const PageId = NodeIdType;

        const FreeSlot = struct {
            digit: KeyInType,
            key: KeyInType,
        };

        model: *Model,

        /// An owned mutable lease for the exact value stored at one unique key.
        pub const ValueEditor = struct {
            const EditorSelf = @This();

            editor: Model.ValueEditorType,

            pub fn valueMut(self: *EditorSelf) Model.ValueEditorType.Error!Model.ValueEditorType.ValueMutType {
                return self.editor.valueMut();
            }

            pub fn finish(self: *EditorSelf) Model.ValueEditorType.Error!void {
                return self.editor.finish();
            }

            pub fn deinit(self: *EditorSelf) void {
                self.editor.deinit();
            }
        };

        /// Owns the loaded leaf that keeps this exact point lookup valid.
        pub const Entry = struct {
            const EntrySelf = @This();

            pub const Result = struct {
                key: KeyInType,
                value: ValueOutType,
            };

            model: ?*Model,
            leaf: LeafType,
            key: KeyInType,
            digit: KeyInType,
            structural_generation: u64,

            /// Returns a value borrowed from this entry when the model uses borrowed outputs.
            pub fn get(self: *const EntrySelf) Error!Result {
                _ = try self.usableModel();
                return .{
                    .key = self.key,
                    .value = try self.leaf.get(self.digit),
                };
            }

            pub fn editValue(self: *EntrySelf) Error!ValueEditor {
                const model = try self.usableModel();
                return .{
                    .editor = try model.accessor().openValueEditor(&self.leaf, self.digit),
                };
            }

            pub fn deinit(self: *EntrySelf) void {
                const model = self.model orelse return;
                model.accessor().deinitLeaf(&self.leaf);
                model.structuralMutationCoordinator().finishReadHandle();
                self.model = null;
                self.leaf = undefined;
            }

            fn usableModel(self: *const EntrySelf) Error!*Model {
                const model = self.model orelse return error.InvalidHandle;
                try model.structuralMutationCoordinator().checkGeneration(
                    self.structural_generation,
                );
                return model;
            }
        };

        pub fn init(model: *Model) Self {
            return .{ .model = model };
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        /// Releases every node reachable from the root and empties the free-leaf list.
        /// This operation is not failure-atomic. Use rollback-capable storage or a
        /// transaction when `destroyPage` can fail.
        pub fn destroy(self: *Self) Error!void {
            var mutation = try self.model.structuralMutationCoordinator().beginStructuralMutation();
            defer mutation.deinit();
            const acc = self.accessor();
            const root_id = (try acc.getRoot()) orelse return;
            try self.destroyNode(root_id);
            try acc.setRoot(null);
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

        fn debugPrintSplitKey(key: KeyInType, skr: *const SplitKeyType) void {
            if (@import("builtin").mode == .Debug) {
                std.debug.print("Key 0x{X:0>8} -> {} levels:\n", .{ key, skr.size() });
                for (0..skr.size()) |i| {
                    const kd = skr.get(i);
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
            const acc = self.accessor();

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
            const acc = self.accessor();

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

        /// Convenience lookup for models whose output remains valid after the
        /// leaf is released. Borrowing models must use `find()` instead.
        pub fn get(self: *Self, key: KeyInType) Error!?ValueOutType {
            const acc = self.accessor();
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

        /// Finds one exact key and keeps its leaf loaded until `Entry.deinit()`.
        pub fn find(self: *const Self, key: KeyInType) Error!?Entry {
            const acc = self.accessor();
            var split_key = try acc.splitKey(key);
            defer acc.deinitSplitKey(&split_key);
            var leaf = (try self.findLeaf(&split_key)) orelse return null;
            errdefer acc.deinitLeaf(&leaf);
            const digit = split_key.get(0).digit;
            if (!try leaf.isSet(digit)) {
                acc.deinitLeaf(&leaf);
                return null;
            }
            const coordinator = self.model.structuralMutationCoordinator();
            try coordinator.beginReadHandle();
            return .{
                .model = self.model,
                .leaf = leaf,
                .key = key,
                .digit = digit,
                .structural_generation = coordinator.generation(),
            };
        }

        pub fn set(self: *Self, key: KeyInType, value: ValueInType) Error!void {
            var mutation = try self.model.structuralMutationCoordinator().beginStructuralMutation();
            defer mutation.deinit();
            const acc = self.accessor();
            var split_key = try acc.splitKey(key);
            defer acc.deinitSplitKey(&split_key);
            //debugPrintSplitKey(key, &split_key);
            try self.growUpPath(split_key.size() - 1);
            var leaf = try self.createPath(&split_key);
            defer acc.deinitLeaf(&leaf);
            try leaf.set(split_key.get(0).digit, value);
            try self.syncFreeLeaf(&leaf);
        }

        /// Stores `value` in an existing free leaf slot and returns its full key.
        pub fn takeFree(self: *Self, value: ValueInType) Error!?KeyInType {
            var mutation = try self.model.structuralMutationCoordinator().beginStructuralMutation();
            defer mutation.deinit();
            const acc = self.accessor();
            while (try acc.getFreeLeaf()) |leaf_value| {
                var leaf = leaf_value;
                defer acc.deinitLeaf(&leaf);

                if (!try leaf.isInFree()) {
                    return Error.InconsistentLayout;
                }
                const free_slot = (try self.getRepresentableFreeSlot(&leaf)) orelse {
                    try acc.removeFreeLeaf(leaf.id());
                    continue;
                };
                const has_more = try self.hasRepresentableFreeSlotAfter(
                    &leaf,
                    free_slot.digit,
                );
                if (!has_more) {
                    try acc.removeFreeLeaf(leaf.id());
                }
                leaf.set(free_slot.digit, value) catch |err| {
                    if (!has_more) {
                        acc.addFreeLeaf(&leaf) catch |restore_err| {
                            // Restoration failure requires external storage rollback.
                            return restore_err;
                        };
                    }
                    return err;
                };
                return free_slot.key;
            }
            return null;
        }

        pub fn free(self: *Self, key: KeyInType) Error!void {
            var mutation = try self.model.structuralMutationCoordinator().beginStructuralMutation();
            defer mutation.deinit();
            const acc = self.accessor();
            var split_key = try acc.splitKey(key);
            defer acc.deinitSplitKey(&split_key);
            var leaf_value = try self.findLeaf(&split_key);
            if (leaf_value) |*leaf| {
                var leaf_active = true;
                defer if (leaf_active) {
                    acc.deinitLeaf(leaf);
                };
                const digit = split_key.get(0).digit;
                if (try leaf.isSet(digit)) {
                    try leaf.free(digit);
                    if (try leaf.size() == 0) {
                        if (try leaf.isInFree()) {
                            try acc.removeFreeLeaf(leaf.id());
                        }
                        const parent = try leaf.getParent();
                        const parent_id = try leaf.getParentId();
                        const leaf_id = leaf.id();
                        acc.deinitLeaf(leaf);
                        leaf_active = false;
                        try acc.destroy(leaf_id);
                        if (parent == null) {
                            try acc.setRoot(null);
                        } else {
                            try self.freeChild(parent, parent_id);
                        }
                        return;
                    }
                    try self.syncFreeLeaf(leaf);
                }
                // The deferred cleanup owns the nonempty leaf.
            }
        }

        /// Opens a mutable editor for the value at `key`, if the unique key exists.
        pub fn openValueEditor(self: *Self, key: KeyInType) Error!?ValueEditor {
            const acc = self.accessor();
            var split_key = try acc.splitKey(key);
            defer acc.deinitSplitKey(&split_key);
            var leaf = (try self.findLeaf(&split_key)) orelse return null;
            defer acc.deinitLeaf(&leaf);
            const digit = split_key.get(0).digit;
            if (!try leaf.isSet(digit)) {
                return null;
            }
            return .{ .editor = try acc.openValueEditor(&leaf, digit) };
        }

        fn freeChild(self: *Self, inode_id: ?NodeIdType, id: KeyInType) Error!void {
            const acc = self.accessor();
            if (inode_id) |pid| {
                var inode = try acc.loadInode(pid);
                var inode_active = true;
                defer if (inode_active) {
                    acc.deinitInode(&inode);
                };
                if (try inode.isSet(id)) {
                    try inode.free(id);
                    if (try inode.size() == 0) {
                        const parent = try inode.getParent();
                        const parent_id = try inode.getParentId();
                        acc.deinitInode(&inode);
                        inode_active = false;
                        try acc.destroy(pid);
                        if (parent == null) {
                            try acc.setRoot(null);
                        } else {
                            try self.freeChild(parent, parent_id);
                        }
                        return;
                    }
                }
                // The deferred cleanup owns the nonempty inode.
            }
        }

        fn findLeaf(self: *const Self, skr: *const SplitKeyType) Error!?LeafType {
            const acc = self.accessor();
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

        fn destroyNode(self: *Self, node_id: NodeIdType) Error!void {
            const acc = self.accessor();
            if (try acc.isLeaf(node_id)) {
                const listed = blk: {
                    var leaf = try acc.loadLeaf(node_id);
                    defer acc.deinitLeaf(&leaf);
                    break :blk try leaf.isInFree();
                };
                if (listed) {
                    try acc.removeFreeLeaf(node_id);
                }
                return acc.destroy(node_id);
            }

            const capacity = blk: {
                var inode = try acc.loadInode(node_id);
                defer acc.deinitInode(&inode);
                break :blk try inode.capacity();
            };
            for (0..capacity) |index| {
                const child_id = blk: {
                    var inode = try acc.loadInode(node_id);
                    defer acc.deinitInode(&inode);
                    const digit = std.math.cast(KeyInType, index) orelse
                        return Error.InconsistentLayout;
                    if (!try inode.isSet(digit)) {
                        break :blk null;
                    }
                    break :blk try inode.get(digit);
                };
                if (child_id) |id| {
                    try self.destroyNode(id);
                }
            }
            return acc.destroy(node_id);
        }

        fn getRepresentableFreeSlot(self: *Self, leaf: *const LeafType) Error!?FreeSlot {
            const digit = (try leaf.getFirstFree()) orelse return null;
            const key = (try self.keyForLeafDigit(leaf, digit)) orelse return null;
            return .{
                .digit = digit,
                .key = key,
            };
        }

        fn hasRepresentableFreeSlotAfter(
            self: *Self,
            leaf: *const LeafType,
            digit: KeyInType,
        ) Error!bool {
            const capacity = try leaf.capacity();
            const digit_index = std.math.cast(usize, digit) orelse
                return Error.InconsistentLayout;
            var index = digit_index + 1;
            while (index < capacity) : (index += 1) {
                const next_digit = std.math.cast(KeyInType, index) orelse return false;
                if ((try self.keyForLeafDigit(leaf, next_digit)) == null) {
                    return false;
                }
                if (!try leaf.isSet(next_digit)) {
                    return true;
                }
            }
            return false;
        }

        fn keyForLeafDigit(
            self: *Self,
            leaf: *const LeafType,
            digit: KeyInType,
        ) Error!?KeyInType {
            const quotient = try leaf.getParentQuotient();
            const leaf_base = std.math.cast(
                KeyInType,
                self.model.getSettings().leaf_base,
            ) orelse return Error.InconsistentLayout;
            const multiplied = @mulWithOverflow(quotient, leaf_base);
            if (multiplied[1] != 0) {
                return null;
            }
            const key_result = @addWithOverflow(multiplied[0], digit);
            if (key_result[1] != 0) {
                return null;
            }
            return key_result[0];
        }

        fn syncFreeLeaf(self: *Self, leaf: *LeafType) Error!void {
            const acc = self.accessor();
            const size = try leaf.size();
            if (size == 0) {
                return;
            }
            if ((try self.getRepresentableFreeSlot(leaf)) != null) {
                if (!try leaf.isInFree()) {
                    try acc.addFreeLeaf(leaf);
                }
            } else if (try leaf.isInFree()) {
                try acc.removeFreeLeaf(leaf.id());
            }
        }

        fn createPath(self: *Self, skr: *const SplitKeyType) Error!LeafType {
            const acc = self.accessor();
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
            const acc = self.accessor();

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
                        try leaf.setParentId(0);
                        try leaf.setParentQuotient(0);
                        try new_inode.setLevel(1);
                        try new_inode.set(0, leaf.id());
                    } else {
                        var inode = try acc.loadInode(current_id);
                        defer acc.deinitInode(&inode);
                        try inode.setParent(new_inode.id());
                        try inode.setParentId(0);
                        try inode.setParentQuotient(0);
                        const next_level = try inode.getLevel() + 1;
                        try new_inode.setLevel(next_level);
                        try new_inode.set(0, inode.id());
                    }
                    current_id = new_inode.id();
                    try acc.setRoot(current_id);
                }
            }
        }

        fn accessor(self: *const Self) *Model.AccessorType {
            return self.model.accessor();
        }
    };
}
