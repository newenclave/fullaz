const interfaces = @import("models/interfaces.zig");

pub fn Heap(comptime ModelT: type) type {
    comptime interfaces.assertModel(ModelT);

    const NodeId = ModelT.NodeIdType;
    const SlotId = ModelT.SlotIdType;
    const Location = ModelT.LocationType;
    const KeyIn = ModelT.KeyInType;
    const KeyOut = ModelT.KeyOutType;
    const ValueIn = ModelT.ValueInType;
    const ValueOut = ModelT.ValueOutType;
    const Leaf = ModelT.LeafType;
    const Inode = ModelT.InodeType;
    const Accessor = ModelT.AccessorType;

    return struct {
        const Self = @This();

        const LeafGuard = struct {
            acc: *Accessor,
            value: ?Leaf,

            fn init(acc: *Accessor, value: Leaf) LeafGuard {
                return .{ .acc = acc, .value = value };
            }

            fn ptr(self: *LeafGuard) *Leaf {
                return &self.value.?;
            }

            fn take(self: *LeafGuard) Error!Leaf {
                const value = try self.ptr().take();
                self.value = null;
                return value;
            }

            fn deinit(self: *LeafGuard) void {
                if (self.value) |value| {
                    self.acc.deinitLeaf(value);
                    self.value = null;
                }
            }
        };

        const InodeGuard = struct {
            acc: *Accessor,
            value: ?Inode,

            fn init(acc: *Accessor, value: Inode) InodeGuard {
                return .{ .acc = acc, .value = value };
            }

            fn ptr(self: *InodeGuard) *Inode {
                return &self.value.?;
            }

            fn take(self: *InodeGuard) Error!Inode {
                const value = try self.ptr().take();
                self.value = null;
                return value;
            }

            fn deinit(self: *InodeGuard) void {
                if (self.value) |value| {
                    self.acc.deinitInode(value);
                    self.value = null;
                }
            }
        };

        pub const Error = ModelT.Error || error{
            CorruptTree,
            EmptySet,
            MaxDepth,
        };
        pub const PageId = NodeId;

        /// An owned mutable lease for the current top value. The top key and all
        /// heap metadata remain unchanged while the editor is open.
        pub const ValueEditor = struct {
            const EditorSelf = @This();

            editor: ModelT.ValueEditorType,

            pub fn valueMut(self: *EditorSelf) ModelT.ValueEditorType.Error!ModelT.ValueEditorType.ValueMutType {
                return self.editor.valueMut();
            }

            pub fn finish(self: *EditorSelf) ModelT.ValueEditorType.Error!void {
                return self.editor.finish();
            }

            pub fn deinit(self: *EditorSelf) void {
                self.editor.deinit();
            }
        };

        pub fn scanLeafRefs(
            self: *const Self,
            page_id: PageId,
            page: []const u8,
            visitor: anytype,
        ) !void {
            return self.model.scanLeafRefs(page_id, page, visitor);
        }

        pub fn scanInodeRefs(
            self: *const Self,
            page_id: PageId,
            page: []const u8,
            visitor: anytype,
        ) !void {
            return self.model.scanInodeRefs(page_id, page, visitor);
        }

        /// Removes every entry through the normal heap path so associated FSM
        /// slabs are released together with emptied heap pages.
        pub fn clear(self: *Self) Error!void {
            var mutation = try self.model.structuralMutationCoordinator().beginStructuralMutation();
            defer mutation.deinit();
            while (try self.count() != 0) {
                try self.popImpl();
            }
        }

        pub const Peek = struct {
            const PeekSelf = @This();

            model: *ModelT,
            leaf: ?Leaf,

            /// The returned key remains valid until deinit() or heap mutation.
            pub fn key(self: *const PeekSelf) Error!KeyOut {
                if (self.leaf) |*leaf| {
                    return leaf.getKey(0);
                }
                return Error.EmptySet;
            }

            /// The returned value remains valid until deinit() or heap mutation.
            pub fn value(self: *const PeekSelf) Error!ValueOut {
                if (self.leaf) |*leaf| {
                    return leaf.getValue(0);
                }
                return Error.EmptySet;
            }

            pub fn deinit(self: *PeekSelf) void {
                if (self.leaf) |leaf| {
                    self.model.accessor().deinitLeaf(leaf);
                    self.leaf = null;
                }
            }
        };

        /// A top view that can open an owned editor for its exact value.
        pub const MutablePeek = struct {
            const MutablePeekSelf = @This();

            model: *ModelT,
            leaf: ?Leaf,

            pub fn key(self: *const MutablePeekSelf) Error!KeyOut {
                if (self.leaf) |*leaf| {
                    return leaf.getKey(0);
                }
                return Error.EmptySet;
            }

            pub fn value(self: *const MutablePeekSelf) Error!ValueOut {
                if (self.leaf) |*leaf| {
                    return leaf.getValue(0);
                }
                return Error.EmptySet;
            }

            pub fn editValue(self: *MutablePeekSelf) Error!ValueEditor {
                if (self.leaf) |*leaf| {
                    return .{ .editor = try self.model.accessor().openValueEditor(leaf, 0) };
                }
                return Error.EmptySet;
            }

            pub fn deinit(self: *MutablePeekSelf) void {
                if (self.leaf) |leaf| {
                    self.model.accessor().deinitLeaf(leaf);
                    self.leaf = null;
                }
            }
        };

        model: *ModelT,
        insertion_hint: ?NodeId = null,

        pub fn init(model: *ModelT) Self {
            return .{ .model = model };
        }

        pub fn count(self: *const Self) Error!ModelT.CountType {
            return self.model.getEntriesCount();
        }

        pub fn isEmpty(self: *const Self) Error!bool {
            return (try self.count()) == 0;
        }

        pub fn height(self: *Self) Error!usize {
            const root = self.model.accessor().getRoot() orelse return 0;
            return self.levelOf(root);
        }

        pub fn top(self: *Self) Error!Peek {
            const acc = self.model.accessor();
            const location = acc.getCachedTop() orelse return Error.EmptySet;
            if (location.slot_id != @as(SlotId, 0)) {
                return Error.CorruptTree;
            }
            const leaf = try self.loadLeaf(location.page_id);
            errdefer acc.deinitLeaf(leaf);
            if (try leaf.size() == 0) {
                return Error.CorruptTree;
            }
            return .{ .model = self.model, .leaf = leaf };
        }

        pub fn mutableTop(self: *Self) Error!MutablePeek {
            const acc = self.model.accessor();
            const location = acc.getCachedTop() orelse return Error.EmptySet;
            if (location.slot_id != @as(SlotId, 0)) {
                return Error.CorruptTree;
            }
            const leaf = try self.loadLeaf(location.page_id);
            errdefer acc.deinitLeaf(leaf);
            if (try leaf.size() == 0) {
                return Error.CorruptTree;
            }
            return .{ .model = self.model, .leaf = leaf };
        }

        /// Opens an editor for the current top value without exposing a leaf.
        pub fn openValueEditor(self: *Self) Error!ValueEditor {
            var peek = try self.mutableTop();
            defer peek.deinit();
            return peek.editValue();
        }

        pub fn push(self: *Self, key: KeyIn, value: ValueIn) Error!void {
            var mutation = try self.model.structuralMutationCoordinator().beginStructuralMutation();
            defer mutation.deinit();
            const previous_hint = self.insertion_hint;
            errdefer {
                self.insertion_hint = previous_hint;
            }
            const required = try self.model.requiredLeafSpace(key, value);
            const acc = self.model.accessor();

            if (acc.getRoot() == null) {
                const leaf_id = blk: {
                    var guard = LeafGuard.init(acc, try acc.createLeaf());
                    const created_id = guard.ptr().id();
                    errdefer acc.destroy(created_id) catch {};
                    defer guard.deinit();
                    _ = try guard.ptr().push(key, value);
                    try acc.addLeafSpace(created_id, try guard.ptr().availableAfterCompact());
                    break :blk created_id;
                };
                try acc.setRoot(leaf_id);
                try acc.setCachedTop(self.leafLocation(leaf_id));
                self.insertion_hint = leaf_id;
                try self.model.incrementEntriesCount();
                return;
            }

            if (try self.findLeafForPush(required, key, value)) |leaf_value| {
                var guard = LeafGuard.init(acc, leaf_value);
                defer guard.deinit();
                const leaf_id = guard.ptr().id();
                const change = try guard.ptr().push(key, value);
                try acc.updateLeafSpace(leaf_id, try guard.ptr().availableAfterCompact());
                self.insertion_hint = leaf_id;
                if (change == .changed) {
                    try self.propagateLeafOwned(try guard.take());
                }
                try self.model.incrementEntriesCount();
                return;
            }

            const leaf_id = blk: {
                var guard = LeafGuard.init(acc, try acc.createLeaf());
                const created_id = guard.ptr().id();
                errdefer acc.destroy(created_id) catch {};
                defer guard.deinit();
                _ = try guard.ptr().push(key, value);
                try acc.addLeafSpace(created_id, try guard.ptr().availableAfterCompact());
                break :blk created_id;
            };
            try self.attachSubtree(leaf_id, 0);
            self.insertion_hint = leaf_id;
            try self.model.incrementEntriesCount();
        }

        pub fn pop(self: *Self) Error!void {
            var mutation = try self.model.structuralMutationCoordinator().beginStructuralMutation();
            defer mutation.deinit();
            return self.popImpl();
        }

        fn popImpl(self: *Self) Error!void {
            const acc = self.model.accessor();
            const location = acc.getCachedTop() orelse return Error.EmptySet;
            if (location.slot_id != @as(SlotId, 0)) {
                return Error.CorruptTree;
            }
            const leaf_value = try self.loadLeaf(location.page_id);
            var guard = LeafGuard.init(acc, leaf_value);
            defer guard.deinit();
            const leaf_id = guard.ptr().id();
            try guard.ptr().popTop();

            if (try guard.ptr().size() > 0) {
                try acc.updateLeafSpace(leaf_id, try guard.ptr().availableAfterCompact());
                self.insertion_hint = leaf_id;
                try self.propagateLeafOwned(try guard.take());
            } else {
                self.insertion_hint = null;
                try self.removeEmptyLeafOwned(try guard.take());
            }
            try self.model.decrementEntriesCount();
        }

        fn findLeafForPush(
            self: *Self,
            required: ModelT.SpaceType,
            key: KeyIn,
            value: ValueIn,
        ) Error!?Leaf {
            const acc = self.model.accessor();
            if (self.insertion_hint) |hint| {
                if (try acc.loadLeaf(hint)) |leaf| {
                    var guard = LeafGuard.init(acc, leaf);
                    defer guard.deinit();
                    if (try guard.ptr().canPush(key, value)) {
                        return try guard.take();
                    }
                }
                self.insertion_hint = null;
            }

            const leaf_id = (try acc.findLeaf(required)) orelse return null;
            const leaf = try self.loadLeaf(leaf_id);
            var guard = LeafGuard.init(acc, leaf);
            defer guard.deinit();
            if (!(try guard.ptr().canPush(key, value))) {
                return null;
            }
            return try guard.take();
        }

        fn propagateLeafOwned(self: *Self, leaf_value: Leaf) Error!void {
            const acc = self.model.accessor();
            var leaf = LeafGuard.init(acc, leaf_value);
            defer leaf.deinit();
            const parent_id = try leaf.ptr().getParent();
            if (parent_id == null) {
                return acc.setCachedTop(self.leafLocation(leaf.ptr().id()));
            }

            const parent_value = try self.loadInode(parent_id.?);
            var parent = InodeGuard.init(acc, parent_value);
            defer parent.deinit();
            const index = (try parent.ptr().findChild(leaf.ptr().id())) orelse return Error.CorruptTree;
            const key = try leaf.ptr().getKey(0);
            const change = try parent.ptr().updateChild(
                index,
                self.model.keyOutAsIn(key),
                self.leafLocation(leaf.ptr().id()),
            );
            leaf.deinit();
            if (change == .changed) {
                return self.propagateInodeOwned(try parent.take());
            }
        }

        fn propagateInodeOwned(self: *Self, inode_value: Inode) Error!void {
            const acc = self.model.accessor();
            var inode = InodeGuard.init(acc, inode_value);
            defer inode.deinit();
            const parent_id = try inode.ptr().getParent();
            if (parent_id == null) {
                return acc.setCachedTop(try inode.ptr().getWinner(0));
            }

            const parent_value = try self.loadInode(parent_id.?);
            var parent = InodeGuard.init(acc, parent_value);
            defer parent.deinit();
            const index = (try parent.ptr().findChild(inode.ptr().id())) orelse return Error.CorruptTree;
            const key = try inode.ptr().getKey(0);
            const winner = try inode.ptr().getWinner(0);
            const change = try parent.ptr().updateChild(index, self.model.keyOutAsIn(key), winner);
            inode.deinit();
            if (change == .changed) {
                return self.propagateInodeOwned(try parent.take());
            }
        }

        fn attachSubtree(self: *Self, child_id: NodeId, child_level: usize) Error!void {
            const acc = self.model.accessor();
            const root_id = acc.getRoot() orelse {
                try self.setNodeParent(child_id, null);
                try acc.setRoot(child_id);
                return self.refreshCachedTop();
            };
            const root_level = try self.levelOf(root_id);
            if (root_level < child_level) {
                return Error.CorruptTree;
            }

            if (root_level == child_level) {
                const new_root_level = try self.checkedNextLevel(root_level);
                var new_root = InodeGuard.init(acc, try acc.createInode(new_root_level));
                const new_root_id = new_root.ptr().id();
                errdefer acc.destroy(new_root_id) catch {};
                defer new_root.deinit();
                _ = try self.insertChildSummary(new_root.ptr(), root_id);
                errdefer self.setNodeParent(root_id, null) catch {};
                _ = try self.insertChildSummary(new_root.ptr(), child_id);
                errdefer self.setNodeParent(child_id, null) catch {};
                try acc.setRoot(new_root_id);
                if (try new_root.ptr().size() < try new_root.ptr().capacity()) {
                    try self.linkAvailable(new_root.ptr());
                }
                return acc.setCachedTop(try new_root.ptr().getWinner(0));
            }

            const parent_level = try self.checkedNextLevel(child_level);
            if (try acc.getAvailableInode(parent_level)) |parent_id| {
                const parent_value = try self.loadInode(parent_id);
                var parent = InodeGuard.init(acc, parent_value);
                defer parent.deinit();
                if (try parent.ptr().getLevel() != parent_level or
                    !(try parent.ptr().isAvailableLinked()))
                {
                    return Error.CorruptTree;
                }
                const change = try self.insertChildSummary(parent.ptr(), child_id);
                if (try parent.ptr().size() == try parent.ptr().capacity()) {
                    try self.unlinkAvailable(parent.ptr());
                }
                if (change == .changed) {
                    return self.propagateInodeOwned(try parent.take());
                }
                return;
            }

            const bridge_id = blk: {
                var bridge = InodeGuard.init(acc, try acc.createInode(parent_level));
                const created_id = bridge.ptr().id();
                errdefer acc.destroy(created_id) catch {};
                defer bridge.deinit();
                _ = try self.insertChildSummary(bridge.ptr(), child_id);
                errdefer self.setNodeParent(child_id, null) catch {};
                if (try bridge.ptr().size() < try bridge.ptr().capacity()) {
                    try self.linkAvailable(bridge.ptr());
                }
                break :blk created_id;
            };
            return self.attachSubtree(bridge_id, parent_level);
        }

        fn insertChildSummary(self: *Self, parent: *Inode, child_id: NodeId) Error!interfaces.WinnerChange {
            const acc = self.model.accessor();
            const parent_id = parent.id();
            if (try acc.isLeafId(child_id)) {
                var child = try self.loadLeaf(child_id);
                defer acc.deinitLeaf(child);
                if (try child.size() == 0) {
                    return Error.CorruptTree;
                }
                const key = try child.getKey(0);
                const change = try parent.insertChild(
                    self.model.keyOutAsIn(key),
                    child_id,
                    self.leafLocation(child_id),
                );
                try child.setParent(parent_id);
                return change;
            }

            var child = try self.loadInode(child_id);
            defer acc.deinitInode(child);
            if (try child.size() == 0) {
                return Error.CorruptTree;
            }
            const key = try child.getKey(0);
            const winner = try child.getWinner(0);
            const change = try parent.insertChild(self.model.keyOutAsIn(key), child_id, winner);
            try child.setParent(parent_id);
            return change;
        }

        fn removeEmptyLeafOwned(self: *Self, leaf_value: Leaf) Error!void {
            const acc = self.model.accessor();
            var leaf = LeafGuard.init(acc, leaf_value);
            defer leaf.deinit();
            const leaf_id = leaf.ptr().id();
            const parent_id = try leaf.ptr().getParent();
            try acc.removeLeafSpace(leaf_id);

            if (parent_id == null) {
                leaf.deinit();
                try acc.setRoot(null);
                try acc.setCachedTop(null);
                return acc.destroy(leaf_id);
            }

            const parent_value = (try acc.loadInode(parent_id.?)) orelse return Error.CorruptTree;
            var parent = InodeGuard.init(acc, parent_value);
            defer parent.deinit();
            const index = (try parent.ptr().findChild(leaf_id)) orelse return Error.CorruptTree;
            const change = try parent.ptr().removeChild(index);
            leaf.deinit();
            try acc.destroy(leaf_id);
            return self.finishAfterChildRemoval(try parent.take(), change);
        }

        fn finishAfterChildRemoval(self: *Self, inode_value: Inode, change: interfaces.WinnerChange) Error!void {
            const acc = self.model.accessor();
            var inode = InodeGuard.init(acc, inode_value);
            defer inode.deinit();
            const size = try inode.ptr().size();
            if (size == 0) {
                return self.removeEmptyInodeOwned(try inode.take());
            }
            if (size < try inode.ptr().capacity() and !(try inode.ptr().isAvailableLinked())) {
                try self.linkAvailable(inode.ptr());
            }
            if (acc.getRoot() == inode.ptr().id() and size == 1) {
                inode.deinit();
                return self.contractRoot();
            }
            if (change == .changed) {
                return self.propagateInodeOwned(try inode.take());
            }
        }

        fn removeEmptyInodeOwned(self: *Self, inode_value: Inode) Error!void {
            const acc = self.model.accessor();
            var inode = InodeGuard.init(acc, inode_value);
            defer inode.deinit();
            const inode_id = inode.ptr().id();
            if (try inode.ptr().isAvailableLinked()) {
                try self.unlinkAvailable(inode.ptr());
            }
            const parent_id = try inode.ptr().getParent();
            if (parent_id == null) {
                inode.deinit();
                try acc.setRoot(null);
                try acc.setCachedTop(null);
                return acc.destroy(inode_id);
            }

            const parent_value = try self.loadInode(parent_id.?);
            var parent = InodeGuard.init(acc, parent_value);
            defer parent.deinit();
            const index = (try parent.ptr().findChild(inode_id)) orelse return Error.CorruptTree;
            const change = try parent.ptr().removeChild(index);
            inode.deinit();
            try acc.destroy(inode_id);
            return self.finishAfterChildRemoval(try parent.take(), change);
        }

        fn contractRoot(self: *Self) Error!void {
            const acc = self.model.accessor();
            while (acc.getRoot()) |root_id| {
                if (try acc.isLeafId(root_id)) {
                    var leaf = try self.loadLeaf(root_id);
                    defer acc.deinitLeaf(leaf);
                    if (try leaf.size() == 0) {
                        return Error.CorruptTree;
                    }
                    try leaf.setParent(null);
                    return acc.setCachedTop(self.leafLocation(root_id));
                }

                const root_value = try self.loadInode(root_id);
                var root = InodeGuard.init(acc, root_value);
                defer root.deinit();
                const size = try root.ptr().size();
                if (size == 0) {
                    if (try root.ptr().isAvailableLinked()) {
                        try self.unlinkAvailable(root.ptr());
                    }
                    root.deinit();
                    try acc.destroy(root_id);
                    try acc.setRoot(null);
                    return acc.setCachedTop(null);
                }
                if (size > 1) {
                    return acc.setCachedTop(try root.ptr().getWinner(0));
                }

                const child_id = try root.ptr().getChild(0);
                if (try root.ptr().isAvailableLinked()) {
                    try self.unlinkAvailable(root.ptr());
                }
                try self.setNodeParent(child_id, null);
                try acc.setRoot(child_id);
                root.deinit();
                try acc.destroy(root_id);
            }
            return acc.setCachedTop(null);
        }

        fn linkAvailable(self: *Self, inode: *Inode) Error!void {
            const acc = self.model.accessor();
            const size = try inode.size();
            if (size == 0 or size >= try inode.capacity() or try inode.isAvailableLinked()) {
                return Error.CorruptTree;
            }
            const level = try inode.getLevel();
            try self.validateInodeLevel(level);
            const old_head = try acc.getAvailableInode(level);
            try inode.setAvailablePrev(null);
            try inode.setAvailableNext(old_head);
            try inode.setAvailableLinked(true);
            if (old_head) |head_id| {
                var head = try self.loadInode(head_id);
                defer acc.deinitInode(head);
                if (try head.getLevel() != level or !(try head.isAvailableLinked())) {
                    return Error.CorruptTree;
                }
                try head.setAvailablePrev(inode.id());
            }
            try acc.setAvailableInode(level, inode.id());
        }

        fn unlinkAvailable(self: *Self, inode: *Inode) Error!void {
            const acc = self.model.accessor();
            if (!(try inode.isAvailableLinked())) {
                return;
            }
            const level = try inode.getLevel();
            try self.validateInodeLevel(level);
            const previous = try inode.getAvailablePrev();
            const next = try inode.getAvailableNext();
            if (previous) |previous_id| {
                var previous_inode = try self.loadInode(previous_id);
                defer acc.deinitInode(previous_inode);
                try previous_inode.setAvailableNext(next);
            } else {
                if ((try acc.getAvailableInode(level)) != inode.id()) {
                    return Error.CorruptTree;
                }
                try acc.setAvailableInode(level, next);
            }
            if (next) |next_id| {
                var next_inode = try self.loadInode(next_id);
                defer acc.deinitInode(next_inode);
                try next_inode.setAvailablePrev(previous);
            }
            try inode.setAvailablePrev(null);
            try inode.setAvailableNext(null);
            try inode.setAvailableLinked(false);
        }

        fn setNodeParent(self: *Self, node_id: NodeId, parent: ?NodeId) Error!void {
            const acc = self.model.accessor();
            if (try acc.isLeafId(node_id)) {
                var leaf = try self.loadLeaf(node_id);
                defer acc.deinitLeaf(leaf);
                return leaf.setParent(parent);
            }
            var inode = try self.loadInode(node_id);
            defer acc.deinitInode(inode);
            return inode.setParent(parent);
        }

        fn levelOf(self: *Self, node_id: NodeId) Error!usize {
            const acc = self.model.accessor();
            if (try acc.isLeafId(node_id)) {
                return 0;
            }
            var inode = try self.loadInode(node_id);
            defer acc.deinitInode(inode);
            const level = try inode.getLevel();
            try self.validateInodeLevel(level);
            return level;
        }

        fn refreshCachedTop(self: *Self) Error!void {
            const acc = self.model.accessor();
            const root_id = acc.getRoot() orelse return acc.setCachedTop(null);
            if (try acc.isLeafId(root_id)) {
                return acc.setCachedTop(self.leafLocation(root_id));
            }
            var root = try self.loadInode(root_id);
            defer acc.deinitInode(root);
            if (try root.size() == 0) {
                return Error.CorruptTree;
            }
            return acc.setCachedTop(try root.getWinner(0));
        }

        fn leafLocation(_: *const Self, leaf_id: NodeId) Location {
            return .{ .page_id = leaf_id, .slot_id = @as(SlotId, 0) };
        }

        fn checkedNextLevel(self: *const Self, level: usize) Error!usize {
            const result = @addWithOverflow(level, 1);
            if (result[1] != 0 or result[0] > self.model.maxLevel()) {
                return Error.MaxDepth;
            }
            return result[0];
        }

        fn validateInodeLevel(self: *const Self, level: usize) Error!void {
            if (level == 0 or level > self.model.maxLevel()) {
                return Error.CorruptTree;
            }
        }

        fn loadInode(self: *Self, pid: NodeId) Error!Inode {
            const acc = self.model.accessor();
            return (try acc.loadInode(pid)) orelse return Error.CorruptTree;
        }

        fn loadLeaf(self: *Self, pid: NodeId) Error!Leaf {
            const acc = self.model.accessor();
            return (try acc.loadLeaf(pid)) orelse return Error.CorruptTree;
        }
    };
}
