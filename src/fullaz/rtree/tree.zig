const std = @import("std");
const interfaces = @import("models/interfaces.zig");
const strategy_mod = @import("strategy.zig");

pub fn Tree(comptime ModelT: type, comptime StrategyFn: fn (type) type) type {
    comptime interfaces.assertModel(ModelT);

    const Key = ModelT.KeyType;
    const Strategy = StrategyFn(Key);
    comptime strategy_mod.assertStrategy(Strategy, Key);

    const Pid = ModelT.NodeIdType;
    const ValueIn = ModelT.ValueInType;
    const Max = ModelT.max_entries;

    return struct {
        const Self = @This();
        pub const Error = ModelT.Error;
        pub const min_fill: usize = @max(2, Max * 2 / 5);

        const max_depth = 64;
        const Frame = struct {
            id: Pid,
            idx: usize,
        };
        const Path = struct {
            items: [max_depth]Frame = undefined,
            len: usize = 0,
            fn push(self: *Path, f: Frame) void {
                self.items[self.len] = f;
                self.len += 1;
            }
            fn pop(self: *Path) Frame {
                self.len -= 1;
                return self.items[self.len];
            }
        };

        model: *ModelT,

        pub fn init(model: *ModelT) Self {
            return .{ .model = model };
        }

        // ---- search: report values whose box overlaps the query window ---- //
        pub fn search(self: *Self, query: Key, ctx: anytype, cb: anytype) !void {
            const acc = self.model.getAccessor();
            const root = acc.getRoot() orelse {
                return;
            };
            try self.searchNode(root, query, ctx, cb);
        }

        // cb here is: fn(ctx: anytype, mbr: Key, value: ValueIn) anyerror!void
        fn searchNode(self: *Self, id: Pid, query: Key, ctx: anytype, cb: anytype) !void {
            const acc = self.model.getAccessor();
            if (try acc.isLeafId(id)) {
                var leaf = (try acc.loadLeaf(id)).?;
                defer acc.deinitLeaf(leaf);
                const n = try leaf.size();
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const mbr = try leaf.getMbr(i);
                    if (mbr.overlaps(&query)) {
                        try cb(ctx, mbr, try leaf.getValue(i));
                    }
                }
            } else {
                var inode = (try acc.loadInode(id)).?;
                defer acc.deinitInode(inode);
                const n = try inode.size();
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const mbr = try inode.getMbr(i);
                    if (mbr.overlaps(&query)) {
                        try self.searchNode(try inode.getChild(i), query, ctx, cb);
                    }
                }
            }
        }

        // ---- insert ---- //
        pub fn insert(self: *Self, mbr: Key, value: ValueIn) Error!void {
            const acc = self.model.getAccessor();

            const root = acc.getRoot() orelse {
                var leaf = try acc.createLeaf();
                defer acc.deinitLeaf(leaf);
                try leaf.insertEntry(mbr, value);
                try acc.setRoot(leaf.id());
                return;
            };

            // Descend to a leaf, recording (inode id, chosen child index) per level.
            var path = Path{};
            var cur = root;
            while (!(try acc.isLeafId(cur))) {
                var inode = (try acc.loadInode(cur)).?;
                defer acc.deinitInode(inode);
                const n = try inode.size();
                var child_mbrs: [Max]Key = undefined;
                var k: usize = 0;
                while (k < n) : (k += 1) {
                    child_mbrs[k] = try inode.getMbr(k);
                }
                const children_are_leaves = (try inode.getLevel()) == 1;
                const idx = Strategy.chooseSubtree(child_mbrs[0..n], mbr, children_are_leaves);
                path.push(.{ .id = cur, .idx = idx });
                cur = try inode.getChild(idx);
            }

            // Insert into the leaf; split if full.
            var split: ?Pid = null;
            {
                var leaf = (try acc.loadLeaf(cur)).?;
                defer acc.deinitLeaf(leaf);
                if (try leaf.canInsertEntry(mbr, value)) {
                    try leaf.insertEntry(mbr, value);
                } else {
                    split = try self.splitLeaf(&leaf, mbr, value);
                }
            }

            try self.adjustTree(&path, cur, split);
        }

        fn splitLeaf(self: *Self, leaf: anytype, new_mbr: Key, new_value: ValueIn) Error!Pid {
            const acc = self.model.getAccessor();
            const n = try leaf.size();
            var mbrs: [Max + 1]Key = undefined;
            var vals: [Max + 1]ValueIn = undefined;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                mbrs[i] = try leaf.getMbr(i);
                vals[i] = self.model.valueOutAsIn(try leaf.getValue(i));
            }
            mbrs[n] = new_mbr;
            vals[n] = new_value;
            const total = n + 1;

            var assign: [Max + 1]u8 = undefined;
            Strategy.splitEntries(mbrs[0..total], min_fill, assign[0..total]);

            try leaf.clear();
            var sibling = try acc.createLeaf();
            defer acc.deinitLeaf(sibling);
            i = 0;
            while (i < total) : (i += 1) {
                if (assign[i] == 0) {
                    try leaf.insertEntry(mbrs[i], vals[i]);
                } else {
                    try sibling.insertEntry(mbrs[i], vals[i]);
                }
            }
            return sibling.id();
        }

        fn splitInode(self: *Self, inode: anytype, new_mbr: Key, new_child: Pid) Error!Pid {
            const acc = self.model.getAccessor();
            const n = try inode.size();
            var mbrs: [Max + 1]Key = undefined;
            var children: [Max + 1]Pid = undefined;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                mbrs[i] = try inode.getMbr(i);
                children[i] = try inode.getChild(i);
            }
            mbrs[n] = new_mbr;
            children[n] = new_child;
            const total = n + 1;

            var assign: [Max + 1]u8 = undefined;
            Strategy.splitEntries(mbrs[0..total], min_fill, assign[0..total]);

            const level = try inode.getLevel();
            try inode.clear();
            var sibling = try acc.createInode();
            defer acc.deinitInode(sibling);
            try sibling.setLevel(level);
            i = 0;
            while (i < total) : (i += 1) {
                if (assign[i] == 0) {
                    try inode.insertChild(mbrs[i], children[i]);
                } else {
                    try sibling.insertChild(mbrs[i], children[i]);
                }
            }
            return sibling.id();
        }

        fn adjustTree(self: *Self, path: *Path, child_start: Pid, split_start: ?Pid) Error!void {
            const acc = self.model.getAccessor();
            var child_id = child_start;
            var split = split_start;

            while (path.len > 0) {
                const frame = path.pop();
                var parent = (try acc.loadInode(frame.id)).?;
                defer acc.deinitInode(parent);

                try parent.updateChildMbr(frame.idx, try self.nodeMbrOf(child_id));

                if (split) |sib_id| {
                    const sib_mbr = try self.nodeMbrOf(sib_id);
                    if (try parent.canInsertChild(sib_mbr, sib_id)) {
                        try parent.insertChild(sib_mbr, sib_id);
                        split = null;
                    } else {
                        split = try self.splitInode(&parent, sib_mbr, sib_id);
                    }
                }
                child_id = frame.id;
            }

            if (split) |sib_id| {
                var new_root = try acc.createInode();
                defer acc.deinitInode(new_root);
                try new_root.setLevel((try self.levelOf(child_id)) + 1);
                try new_root.insertChild(try self.nodeMbrOf(child_id), child_id);
                try new_root.insertChild(try self.nodeMbrOf(sib_id), sib_id);
                try acc.setRoot(new_root.id());
            }
        }

        fn nodeMbrOf(self: *Self, id: Pid) Error!Key {
            const acc = self.model.getAccessor();
            if (try acc.isLeafId(id)) {
                var l = (try acc.loadLeaf(id)).?;
                defer acc.deinitLeaf(l);
                return try l.nodeMbr();
            }
            var n = (try acc.loadInode(id)).?;
            defer acc.deinitInode(n);
            return try n.nodeMbr();
        }

        fn levelOf(self: *Self, id: Pid) Error!usize {
            const acc = self.model.getAccessor();
            if (try acc.isLeafId(id)) {
                return 0;
            }
            var n = (try acc.loadInode(id)).?;
            defer acc.deinitInode(n);
            return try n.getLevel();
        }

        pub fn height(self: *Self) Error!usize {
            const acc = self.model.getAccessor();
            const root = acc.getRoot() orelse {
                return 0;
            };
            return self.levelOf(root);
        }
    };
}
