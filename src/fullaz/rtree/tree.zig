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
    const ValueBuf = ModelT.ValueBufType;
    const Max = ModelT.max_entries;

    const Leaf = ModelT.LeafType;
    const Inode = ModelT.InodeType;

    return struct {
        const Self = @This();
        pub const Error = ModelT.Error;
        pub const min_fill: usize = @max(2, Max * 2 / 5); // 40% is minimum.

        const max_depth = 64;
        const orphan_cap = max_depth * min_fill;

        const Frame = struct {
            id: Pid,
            idx: usize,
        };

        // TODO: Stack! Needs to be a part of model/accessor API? getPath/deinitPath
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

        // State for R* forced reinsertion during one insert operation.
        // done[level] ensures reinsertion happens only once per level.
        // Any later overflow at the same level is handled by splitting.
        //
        // TODO: Stack! Needs to be a part of model/accessor API? getContext/deinitContext
        const InsertCtx = struct {
            done: [max_depth]bool = [_]bool{false} ** max_depth,

            s_mbr: [orphan_cap]Key = undefined,
            s_id: [orphan_cap]Pid = undefined,
            s_lvl: [orphan_cap]usize = undefined,
            sn: usize = 0,

            v_mbr: [Max + 1]Key = undefined,
            v_val: [Max + 1]ValueBuf = undefined,
            vn: usize = 0,

            fn pushSubtree(self: *InsertCtx, mbr: Key, child_id: Pid, level: usize) void {
                self.s_mbr[self.sn] = mbr;
                self.s_id[self.sn] = child_id;
                self.s_lvl[self.sn] = level;
                self.sn += 1;
            }

            fn pushValue(self: *InsertCtx, mbr: Key, value: ValueBuf) void {
                self.v_mbr[self.vn] = mbr;
                self.v_val[self.vn] = value;
                self.vn += 1;
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
            var ctx = InsertCtx{};
            try self.insertValue(mbr, value, &ctx);
            try self.drainReinserts(&ctx);
        }

        fn insertValue(self: *Self, mbr: Key, value: ValueIn, ctx: *InsertCtx) Error!void {
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
            {
                var leaf = (try acc.loadLeaf(cur)).?;
                defer acc.deinitLeaf(leaf);
                if (try leaf.canInsertEntry(mbr, value)) {
                    try leaf.insertEntry(mbr, value);
                } else if (Strategy.wants_reinsert and !ctx.done[0] and path.len > 0) {
                    ctx.done[0] = true;
                    try self.reinsertLeaf(&leaf, mbr, value, ctx);
                } else {
                    split = try self.splitLeaf(&leaf, mbr, value);
                }
            }

            try self.adjustTree(&path, cur, split, ctx);
        }

        fn drainReinserts(self: *Self, ctx: *InsertCtx) Error!void {
            var si: usize = 0;
            var vi: usize = 0;
            while ((si < ctx.sn) or (vi < ctx.vn)) {
                while (si < ctx.sn) : (si += 1) {
                    try self.insertSubtree(ctx.s_mbr[si], ctx.s_id[si], ctx.s_lvl[si], ctx);
                }
                while (vi < ctx.vn) : (vi += 1) {
                    try self.insertValue(ctx.v_mbr[vi], self.model.valueBufAsIn(&ctx.v_val[vi]), ctx);
                }
            }
        }

        // In place: keep the nearest entries where they sit, eject the farthest
        // ~30% for reinsertion from the root. Only the EJECTED values are copied
        // out (they must outlive this leaf: see ctx/drainReinserts);
        fn reinsertLeaf(self: *Self, leaf: *Leaf, new_mbr: Key, new_value: ValueIn, ctx: *InsertCtx) Error!void {
            const n = try leaf.size();
            const total = n + 1;

            var mbrs: [Max + 1]Key = undefined;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                mbrs[i] = try leaf.getMbr(i);
            }
            mbrs[n] = new_mbr;

            var node_mbr = mbrs[0];
            i = 1;
            while (i < total) : (i += 1) {
                node_mbr = node_mbr.merged(&mbrs[i]);
            }

            var order: [Max + 1]usize = undefined;
            Strategy.reinsertOrder(mbrs[0..total], node_mbr, order[0..total]);

            const p = @max(1, (total * 3) / 10);
            var eject = [_]bool{false} ** (Max + 1);

            i = 0;
            while (i < p) : (i += 1) {
                eject[order[i]] = true;
            }

            i = 0;
            while (i < n) : (i += 1) {
                if (eject[i]) {
                    ctx.pushValue(mbrs[i], self.model.copyValueOut(try leaf.getValue(i)));
                }
            }

            var cursor: usize = 0;
            i = 0;
            while (i < n) : (i += 1) {
                if (eject[i]) {
                    try leaf.erase(i - cursor);
                    cursor += 1;
                }
            }
            try leaf.compact();

            if (eject[n]) {
                ctx.pushValue(new_mbr, self.model.copyValueOut(new_value));
            } else {
                try leaf.insertEntry(new_mbr, new_value);
            }
        }

        // Same in place
        fn reinsertInode(_: *Self, inode: *Inode, new_mbr: Key, new_child: Pid, ctx: *InsertCtx) Error!void {
            const n = try inode.size();
            const total = n + 1;

            var mbrs: [Max + 1]Key = undefined;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                mbrs[i] = try inode.getMbr(i);
            }
            mbrs[n] = new_mbr;

            var node_mbr = mbrs[0];
            i = 1;
            while (i < total) : (i += 1) {
                node_mbr = node_mbr.merged(&mbrs[i]);
            }

            var order: [Max + 1]usize = undefined;
            Strategy.reinsertOrder(mbrs[0..total], node_mbr, order[0..total]);

            const p = @max(1, (total * 3) / 10);
            const level = try inode.getLevel();

            var eject = [_]bool{false} ** (Max + 1);
            i = 0;
            while (i < p) : (i += 1) {
                eject[order[i]] = true;
            }

            i = 0;
            while (i < n) : (i += 1) {
                if (eject[i]) {
                    ctx.pushSubtree(mbrs[i], try inode.getChild(i), level - 1);
                }
            }
            var cursor: usize = 0;
            i = 0;
            while (i < n) : (i += 1) {
                if (eject[i]) {
                    try inode.erase(i - cursor);
                    cursor += 1;
                }
            }
            try inode.compact();

            if (eject[n]) {
                ctx.pushSubtree(new_mbr, new_child, level - 1);
            } else {
                try inode.insertChild(new_mbr, new_child);
            }
        }

        // Split in place: We dont need buffers for values anymore
        fn splitLeaf(self: *Self, leaf: *Leaf, new_mbr: Key, new_value: ValueIn) Error!Pid {
            const acc = self.model.getAccessor();
            const n = try leaf.size();
            const total = n + 1;

            var mbrs: [Max + 1]Key = undefined;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                mbrs[i] = try leaf.getMbr(i);
            }
            mbrs[n] = new_mbr;

            var assign: [Max + 1]u8 = undefined;
            Strategy.splitEntries(mbrs[0..total], min_fill, assign[0..total]);

            var sibling = try acc.createLeaf();
            defer acc.deinitLeaf(sibling);

            i = 0;
            while (i < n) : (i += 1) {
                if (assign[i] != 0) {
                    try sibling.insertEntry(mbrs[i], self.model.valueOutAsIn(try leaf.getValue(i)));
                }
            }

            // erasing the moved values
            var cursor: usize = 0;
            i = 0;
            while (i < n) : (i += 1) {
                if (assign[i] != 0) {
                    try leaf.erase(i - cursor);
                    cursor += 1;
                }
            }
            try leaf.compact();

            // the new value.
            if (assign[n] != 0) {
                try sibling.insertEntry(new_mbr, new_value);
            } else {
                try leaf.insertEntry(new_mbr, new_value);
            }
            return sibling.id();
        }

        // Same in-place move for inodes
        fn splitInode(self: *Self, inode: *Inode, new_mbr: Key, new_child: Pid) Error!Pid {
            const acc = self.model.getAccessor();
            const n = try inode.size();
            const total = n + 1;

            var mbrs: [Max + 1]Key = undefined;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                mbrs[i] = try inode.getMbr(i);
            }
            mbrs[n] = new_mbr;

            var assign: [Max + 1]u8 = undefined;
            Strategy.splitEntries(mbrs[0..total], min_fill, assign[0..total]);

            const level = try inode.getLevel();
            var sibling = try acc.createInode();
            defer acc.deinitInode(sibling);
            try sibling.setLevel(level);

            i = 0;
            while (i < n) : (i += 1) {
                if (assign[i] != 0) {
                    try sibling.insertChild(mbrs[i], try inode.getChild(i));
                }
            }
            var cursor: usize = 0;
            i = 0;
            while (i < n) : (i += 1) {
                if (assign[i] != 0) {
                    try inode.erase(i - cursor);
                    cursor += 1;
                }
            }
            try inode.compact();
            if (assign[n] != 0) {
                try sibling.insertChild(new_mbr, new_child);
            } else {
                try inode.insertChild(new_mbr, new_child);
            }
            return sibling.id();
        }

        fn adjustTree(self: *Self, path: *Path, child_start: Pid, split_start: ?Pid, ctx: *InsertCtx) Error!void {
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
                        // 'path.len > 0' here means 'parent' is not the root.
                        const level = try parent.getLevel();
                        if (Strategy.wants_reinsert and path.len > 0 and !ctx.done[level]) {
                            ctx.done[level] = true;
                            try self.reinsertInode(&parent, sib_mbr, sib_id, ctx);
                            split = null;
                        } else {
                            split = try self.splitInode(&parent, sib_mbr, sib_id);
                        }
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
        // TODO: Same as Frame.
        const Hit = struct {
            leaf_id: Pid,
            entry_idx: usize,
        };

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

            // The one under-full leaf is detached but NOT destroyed
            // the  page stays valid and we reinsert its entries straight from it.
            var orphan_leaf: ?Pid = null;

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
                    orphan_leaf = leaf_id;
                    remove_child = true;
                }
            }

            while (path.len > 0) {
                const frame = path.pop();
                var parent = (try acc.loadInode(frame.id)).?;
                defer acc.deinitInode(parent);

                if (remove_child) {
                    try parent.erase(frame.idx);
                    // destoy only inodes, leaves should be valid for further reinsertion
                    if (!(try acc.isLeafId(child_id))) {
                        try acc.destroy(child_id);
                    }
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

            var ins_ctx = InsertCtx{};
            {
                var i: usize = 0;
                while (i < sn) : (i += 1) {
                    const oi = order[i];
                    try self.insertSubtree(s_mbr[oi], s_id[oi], s_lvl[oi], &ins_ctx);
                }
            }
            if (orphan_leaf) |olid| {
                var leaf = (try acc.loadLeaf(olid)).?; // must be alive here
                const n = try leaf.size();
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    try self.insertValue(try leaf.getMbr(i), self.model.valueOutAsIn(try leaf.getValue(i)), &ins_ctx);
                }
                acc.deinitLeaf(leaf);
                try acc.destroy(olid);
            }

            try self.drainReinserts(&ins_ctx);

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

        fn insertSubtree(self: *Self, mbr: Key, child_id: Pid, target_level: usize, ctx: *InsertCtx) Error!void {
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
            try self.adjustTree(&path, cur, split, ctx);
        }
    };
}
