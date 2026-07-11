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

        // cb here is: fn(ctx: anytype, mbr: Key, value: ValueIn) anyerror!void //
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
            var reinserted = false;
            try self.insertValue(mbr, value, &reinserted);
        }

        fn insertValue(self: *Self, mbr: Key, value: ValueIn, reinserted: *bool) Error!void {
            const acc = self.model.getAccessor();

            const root = acc.getRoot() orelse {
                var leaf = try acc.createLeaf();
                defer acc.deinitLeaf(leaf);
                try leaf.insertEntry(mbr, value);
                try acc.setRoot(leaf.id());
                return;
            };

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

            var split: ?Pid = null;
            var reinsert_n: usize = 0;
            var r_mbr: [Max + 1]Key = undefined;
            var r_val: [Max + 1]ValueIn = undefined;
            {
                var leaf = (try acc.loadLeaf(cur)).?;
                defer acc.deinitLeaf(leaf);
                if (try leaf.canInsertEntry(mbr, value)) {
                    try leaf.insertEntry(mbr, value);
                } else if (Strategy.wants_reinsert) {
                    if (!reinserted.* and path.len > 0) {
                        reinserted.* = true;
                        reinsert_n = try self.reinsertLeaf(&leaf, mbr, value, &r_mbr, &r_val);
                    } else {
                        split = try self.splitLeaf(&leaf, mbr, value);
                    }
                } else {
                    split = try self.splitLeaf(&leaf, mbr, value);
                }
            }

            try self.adjustTree(&path, cur, split);

            var i: usize = 0;
            while (i < reinsert_n) : (i += 1) {
                try self.insertValue(r_mbr[i], r_val[i], reinserted);
            }
        }

        fn reinsertLeaf(self: *Self, leaf: anytype, new_mbr: Key, new_value: ValueIn, out_mbr: []Key, out_val: []ValueIn) Error!usize {
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

            var node_mbr = mbrs[0];
            i = 1;
            while (i < total) : (i += 1) {
                node_mbr = node_mbr.merged(&mbrs[i]);
            }

            var order: [Max + 1]usize = undefined;
            Strategy.reinsertOrder(mbrs[0..total], node_mbr, order[0..total]);

            const p = @max(1, (total * 3) / 10);

            try leaf.clear();
            i = p;
            while (i < total) : (i += 1) {
                try leaf.insertEntry(mbrs[order[i]], vals[order[i]]);
            }
            i = 0;
            while (i < p) : (i += 1) {
                out_mbr[i] = mbrs[order[i]];
                out_val[i] = vals[order[i]];
            }
            return p;
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

        // ---- delete ---- //
        const Hit = struct {
            leaf_id: Pid,
            entry_idx: usize,
        };

        const orphan_cap = max_depth * Max;

        pub fn remove(self: *Self, query: Key, ctx: anytype, matches: anytype) Error!bool {
            const acc = self.model.getAccessor();
            const root = acc.getRoot() orelse {
                return false;
            };

            var path = Path{};
            const hit = (try self.findLeaf(root, query, ctx, matches, &path)) orelse {
                return false;
            };

            {
                var leaf = (try acc.loadLeaf(hit.leaf_id)).?;
                defer acc.deinitLeaf(leaf);
                try leaf.erase(hit.entry_idx);
            }

            try self.condenseTree(&path, hit.leaf_id);
            return true;
        }

        fn findLeaf(self: *Self, id: Pid, query: Key, ctx: anytype, matches: anytype, path: *Path) Error!?Hit {
            const acc = self.model.getAccessor();
            if (try acc.isLeafId(id)) {
                var leaf = (try acc.loadLeaf(id)).?;
                defer acc.deinitLeaf(leaf);

                const n = try leaf.size();
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const mbr = try leaf.getMbr(i);
                    if (mbr.overlaps(&query) and matches(ctx, mbr, try leaf.getValue(i))) {
                        return .{
                            .leaf_id = id,
                            .entry_idx = i,
                        };
                    }
                }
                return null;
            }
            var inode = (try acc.loadInode(id)).?;
            defer acc.deinitInode(inode);
            const n = try inode.size();
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if ((try inode.getMbr(i)).overlaps(&query)) {
                    path.push(.{ .id = id, .idx = i });
                    if (try self.findLeaf(try inode.getChild(i), query, ctx, matches, path)) |hit| {
                        return hit;
                    }
                    _ = path.pop();
                }
            }
            return null;
        }

        fn condenseTree(self: *Self, path: *Path, leaf_id: Pid) Error!void {
            const acc = self.model.getAccessor();

            var v_mbr: [Max]Key = undefined;
            var v_val: [Max]ValueIn = undefined;
            var vn: usize = 0;

            var s_mbr: [orphan_cap]Key = undefined;
            var s_id: [orphan_cap]Pid = undefined;
            var s_lvl: [orphan_cap]usize = undefined;
            var sn: usize = 0;

            var child_id = leaf_id;
            var remove_child = false;

            {
                var leaf = (try acc.loadLeaf(leaf_id)).?;
                defer acc.deinitLeaf(leaf);
                if ((path.len > 0) and (try leaf.size()) < min_fill) {
                    const n = try leaf.size();
                    var i: usize = 0;
                    while (i < n) : (i += 1) {
                        v_mbr[vn] = try leaf.getMbr(i);
                        v_val[vn] = self.model.valueOutAsIn(try leaf.getValue(i));
                        vn += 1;
                    }
                    remove_child = true;
                }
            }

            while (path.len > 0) {
                const frame = path.pop();
                var parent = (try acc.loadInode(frame.id)).?;
                defer acc.deinitInode(parent);

                if (remove_child) {
                    try parent.erase(frame.idx);
                    try acc.destroy(child_id);
                } else {
                    try parent.updateChildMbr(frame.idx, try self.nodeMbrOf(child_id));
                }

                const is_root = path.len == 0;
                if (!is_root and (try parent.size()) < min_fill) {
                    const plvl = try parent.getLevel();
                    const n = try parent.size();
                    var i: usize = 0;
                    while (i < n) : (i += 1) {
                        s_mbr[sn] = try parent.getMbr(i);
                        s_id[sn] = try parent.getChild(i);
                        s_lvl[sn] = plvl - 1;
                        sn += 1;
                    }
                    remove_child = true;
                } else {
                    remove_child = false;
                }
                child_id = frame.id;
            }

            if (!(try acc.isLeafId(child_id))) {
                if (try acc.loadInode(child_id)) |*rv| {
                    const rs = try rv.size();
                    acc.deinitInode(rv.*);
                    if (rs == 0) {
                        try acc.destroy(child_id);
                        try acc.setRoot(null);
                    }
                }
            }

            var order: [orphan_cap]usize = undefined;
            {
                var i: usize = 0;
                while (i < sn) : (i += 1) {
                    order[i] = i;
                }
            }
            const LvlCtx = struct { lvl: []const usize };
            const lt_call = struct {
                fn desc(c: LvlCtx, a: usize, b: usize) bool {
                    return c.lvl[a] > c.lvl[b];
                }
            };
            std.mem.sort(usize, order[0..sn], LvlCtx{ .lvl = s_lvl[0..sn] }, lt_call.desc);
            {
                var i: usize = 0;
                while (i < sn) : (i += 1) {
                    const oi = order[i];
                    try self.insertSubtree(s_mbr[oi], s_id[oi], s_lvl[oi]);
                }
            }

            var flag = false;
            {
                var i: usize = 0;
                while (i < vn) : (i += 1) {
                    try self.insertValue(v_mbr[i], v_val[i], &flag);
                }
            }

            while (true) {
                const root = acc.getRoot() orelse {
                    break;
                };
                if (try acc.isLeafId(root)) break;
                var r = (try acc.loadInode(root)).?;
                const rs = try r.size();
                const only: ?Pid = if (rs == 1) try r.getChild(0) else null;
                acc.deinitInode(r);
                if (only) |child| {
                    try acc.destroy(root);
                    try acc.setRoot(child);
                } else {
                    break;
                }
            }
        }

        fn insertSubtree(self: *Self, mbr: Key, child_id: Pid, target_level: usize) Error!void {
            const acc = self.model.getAccessor();

            const root = acc.getRoot() orelse {
                try acc.setRoot(child_id);
                return;
            };

            if ((try self.levelOf(root)) <= target_level) {
                var nr = try acc.createInode();
                defer acc.deinitInode(nr);
                try nr.setLevel(target_level + 1);
                try nr.insertChild(try self.nodeMbrOf(root), root);
                try nr.insertChild(mbr, child_id);
                try acc.setRoot(nr.id());
                return;
            }

            var path = Path{};
            var cur = root;
            while ((try self.levelOf(cur)) > target_level + 1) {
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

            var split: ?Pid = null;
            {
                var inode = (try acc.loadInode(cur)).?;
                defer acc.deinitInode(inode);
                if (try inode.canInsertChild(mbr, child_id)) {
                    try inode.insertChild(mbr, child_id);
                } else {
                    split = try self.splitInode(&inode, mbr, child_id);
                }
            }
            try self.adjustTree(&path, cur, split);
        }
    };
}
