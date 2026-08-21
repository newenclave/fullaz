const std = @import("std");
const contract_interfaces = @import("../../contracts/interfaces.zig");
const interfaces = @import("models/interfaces.zig");
const limits = @import("limits.zig");
const strategy_mod = @import("strategy.zig");

pub fn Tree(comptime ModelT: type, comptime StrategyFn: fn (type) type) type {
    return TreeWithConfig(ModelT, StrategyFn, ExactConfig(ModelT.KeyType));
}

pub fn FatTree(
    comptime ModelT: type,
    comptime StrategyFn: fn (type) type,
    comptime margin: ModelT.KeyType.Coord,
) type {
    comptime assertFatKey(ModelT.KeyType);
    return TreeWithConfig(ModelT, StrategyFn, FatConfig(ModelT.KeyType, margin));
}

/// A fat key must satisfy the regular key contract and support containment and expansion.
///
/// ```zig
/// const Key = struct {
///     pub const Coord = i64;
///     pub fn containsBox(self: *const Key, other: *const Key) bool { _ = self; _ = other; return true; }
///     pub fn expanded(self: *const Key, margin: Coord) Key { _ = margin; return self.*; }
///     // Also implement the operations required by `interfaces.assertKey`.
/// };
/// comptime assertFatKey(Key);
/// ```
pub fn assertFatKey(comptime KeyT: type) void {
    interfaces.assertKey(KeyT);

    const Coord = KeyT.Coord;
    contract_interfaces.requiresFnSignature(KeyT, "containsBox", fn (*const KeyT, *const KeyT) bool);
    contract_interfaces.requiresFnSignature(KeyT, "expanded", fn (*const KeyT, Coord) KeyT);
}

fn ExactConfig(comptime KeyT: type) type {
    return struct {
        pub fn makeInodeMbr(mbr: KeyT) KeyT {
            return mbr;
        }

        pub fn mustUpdateInodeMbr(_: KeyT, _: KeyT) bool {
            return true;
        }
    };
}

fn FatConfig(comptime KeyT: type, comptime margin: KeyT.Coord) type {
    return struct {
        pub fn makeInodeMbr(mbr: KeyT) KeyT {
            return mbr.expanded(margin);
        }

        pub fn mustUpdateInodeMbr(stored: KeyT, child: KeyT) bool {
            return !stored.containsBox(&child);
        }
    };
}

fn TreeWithConfig(
    comptime ModelT: type,
    comptime StrategyFn: fn (type) type,
    comptime ConfigT: type,
) type {
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

        const max_depth = limits.max_depth;
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

        fn callbackInfo(comptime CallbackT: type) std.builtin.Type.Fn {
            return switch (@typeInfo(CallbackT)) {
                .@"fn" => |info| info,
                .pointer => |pointer| switch (@typeInfo(pointer.child)) {
                    .@"fn" => |info| info,
                    else => @compileError("R-tree callback must be a function or function pointer"),
                },
                else => @compileError("R-tree callback must be a function or function pointer"),
            };
        }

        fn CallbackError(comptime CallbackT: type) type {
            const ReturnT = callbackInfo(CallbackT).return_type orelse
                @compileError("R-tree callback must have a return type");
            return switch (@typeInfo(ReturnT)) {
                .void => error{},
                .error_union => |error_union| blk: {
                    if (error_union.payload != void) {
                        @compileError("R-tree callback must return void or an error union with void payload");
                    }
                    break :blk error_union.error_set;
                },
                else => @compileError("R-tree callback must return void or an error union with void payload"),
            };
        }

        fn callCallback(
            callback: anytype,
            context: anytype,
            mbr: Key,
            value: ValueIn,
        ) CallbackError(@TypeOf(callback))!void {
            const ReturnT = callbackInfo(@TypeOf(callback)).return_type.?;
            switch (@typeInfo(ReturnT)) {
                .void => callback(context, mbr, value),
                .error_union => try callback(context, mbr, value),
                else => unreachable,
            }
        }

        // ---- search: report values whose box has positive overlap with the query window ---- //
        pub fn search(
            self: *const Self,
            query: Key,
            ctx: anytype,
            cb: anytype,
        ) (Error || CallbackError(@TypeOf(cb)))!void {
            const acc = self.model.accessor();
            const root = acc.getRoot() orelse {
                return;
            };
            try self.searchNode(root, query, ctx, cb, .overlap);
        }

        // ---- searchIntersecting: report values sharing any point with the query window ---- //
        pub fn searchIntersecting(
            self: *const Self,
            query: Key,
            ctx: anytype,
            cb: anytype,
        ) (Error || CallbackError(@TypeOf(cb)))!void {
            const acc = self.model.accessor();
            const root = acc.getRoot() orelse {
                return;
            };
            try self.searchNode(root, query, ctx, cb, .intersection);
        }

        const SearchMode = enum {
            overlap,
            intersection,
        };

        fn searchNode(
            self: *const Self,
            id: Pid,
            query: Key,
            ctx: anytype,
            cb: anytype,
            comptime search_mode: SearchMode,
        ) (Error || CallbackError(@TypeOf(cb)))!void {
            const acc = self.model.accessor();
            if (try acc.isLeafId(id)) {
                var leaf = (try acc.loadLeaf(id)).?;
                defer acc.deinitLeaf(leaf);
                const n = try leaf.size();
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const mbr = try leaf.getMbr(i);
                    const matches = switch (search_mode) {
                        .intersection => mbr.intersects(&query),
                        .overlap => mbr.overlaps(&query),
                    };
                    if (matches) {
                        try callCallback(cb, ctx, mbr, try leaf.getValue(i));
                    }
                }
            } else {
                var child_ids: [Max]Pid = undefined;
                const child_count = blk: {
                    var inode = (try acc.loadInode(id)).?;
                    defer acc.deinitInode(inode);
                    const n = try inode.size();
                    var count: usize = 0;
                    var i: usize = 0;
                    while (i < n) : (i += 1) {
                        const mbr = try inode.getMbr(i);
                        const matches = switch (search_mode) {
                            .intersection => mbr.intersects(&query),
                            .overlap => mbr.overlaps(&query),
                        };
                        if (matches) {
                            child_ids[count] = try inode.getChild(i);
                            count += 1;
                        }
                    }
                    break :blk count;
                };
                for (child_ids[0..child_count]) |child_id| {
                    try self.searchNode(child_id, query, ctx, cb, search_mode);
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
            const acc = self.model.accessor();

            const root = acc.getRoot() orelse {
                var leaf = try acc.createLeaf();
                errdefer acc.destroy(leaf.id()) catch {};
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
        fn reinsertInode(self: *Self, inode: *Inode, new_mbr: Key, new_child: Pid, ctx: *InsertCtx) Error!void {
            const n = try inode.size();
            const total = n + 1;

            var mbrs: [Max + 1]Key = undefined;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                mbrs[i] = try inode.getMbr(i);
            }
            mbrs[n] = ConfigT.makeInodeMbr(new_mbr);

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
                    const child_id = try inode.getChild(i);
                    ctx.pushSubtree(try self.nodeMbrOf(child_id), child_id, level - 1);
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
                try inode.insertChild(mbrs[n], new_child);
            }
        }

        // Split in place: We dont need buffers for values anymore
        fn splitLeaf(self: *Self, leaf: *Leaf, new_mbr: Key, new_value: ValueIn) Error!Pid {
            const acc = self.model.accessor();
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
            errdefer acc.destroy(sibling.id()) catch {};
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
            const acc = self.model.accessor();
            const n = try inode.size();
            const total = n + 1;

            var mbrs: [Max + 1]Key = undefined;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                mbrs[i] = try inode.getMbr(i);
            }
            mbrs[n] = ConfigT.makeInodeMbr(new_mbr);

            var assign: [Max + 1]u8 = undefined;
            Strategy.splitEntries(mbrs[0..total], min_fill, assign[0..total]);

            const level = try inode.getLevel();
            var sibling = try acc.createInode();
            errdefer acc.destroy(sibling.id()) catch {};
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
                try sibling.insertChild(mbrs[n], new_child);
            } else {
                try inode.insertChild(mbrs[n], new_child);
            }
            return sibling.id();
        }

        fn adjustTree(self: *Self, path: *Path, child_start: Pid, split_start: ?Pid, ctx: *InsertCtx) Error!void {
            const acc = self.model.accessor();
            var child_id = child_start;
            var split = split_start;

            while (path.len > 0) {
                const frame = path.pop();
                var parent = (try acc.loadInode(frame.id)).?;
                defer acc.deinitInode(parent);

                try self.updateParentMbr(&parent, frame.idx, child_id);

                if (split) |sib_id| {
                    const sib_mbr = try self.nodeMbrOf(sib_id);
                    if (try parent.canInsertChild(sib_mbr, sib_id)) {
                        try parent.insertChild(ConfigT.makeInodeMbr(sib_mbr), sib_id);
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
                errdefer acc.destroy(new_root.id()) catch {};
                defer acc.deinitInode(new_root);
                try new_root.setLevel((try self.levelOf(child_id)) + 1);
                try new_root.insertChild(
                    ConfigT.makeInodeMbr(try self.nodeMbrOf(child_id)),
                    child_id,
                );
                try new_root.insertChild(
                    ConfigT.makeInodeMbr(try self.nodeMbrOf(sib_id)),
                    sib_id,
                );
                try acc.setRoot(new_root.id());
            }
        }

        fn updateParentMbr(self: *Self, parent: *Inode, child_idx: usize, child_id: Pid) Error!void {
            const child_mbr = try self.nodeMbrOf(child_id);
            const stored_mbr = try parent.getMbr(child_idx);
            if (ConfigT.mustUpdateInodeMbr(stored_mbr, child_mbr)) {
                try parent.updateChildMbr(child_idx, ConfigT.makeInodeMbr(child_mbr));
            }
        }

        fn nodeMbrOf(self: *const Self, id: Pid) Error!Key {
            const acc = self.model.accessor();
            if (try acc.isLeafId(id)) {
                var l = (try acc.loadLeaf(id)).?;
                defer acc.deinitLeaf(l);
                return try l.nodeMbr();
            }
            var n = (try acc.loadInode(id)).?;
            defer acc.deinitInode(n);
            return try n.nodeMbr();
        }

        fn levelOf(self: *const Self, id: Pid) Error!usize {
            const acc = self.model.accessor();
            if (try acc.isLeafId(id)) {
                return 0;
            }
            var n = (try acc.loadInode(id)).?;
            defer acc.deinitInode(n);
            return try n.getLevel();
        }

        pub fn height(self: *const Self) Error!usize {
            const acc = self.model.accessor();
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
            const acc = self.model.accessor();
            const root = acc.getRoot() orelse {
                return false;
            };

            var path = Path{};
            const hit = (try self.findLeaf(root, query, ctx, matches, &path)) orelse {
                return false;
            };

            const leaf_is_empty = blk: {
                var leaf = (try acc.loadLeaf(hit.leaf_id)).?;
                defer acc.deinitLeaf(leaf);
                try leaf.erase(hit.entry_idx);
                break :blk (try leaf.size()) == 0;
            };

            if (root == hit.leaf_id and leaf_is_empty) {
                try acc.setRoot(null);
                try acc.destroy(hit.leaf_id);
                return true;
            }

            try self.condenseTree(&path, hit.leaf_id);
            return true;
        }

        fn findLeaf(self: *Self, id: Pid, query: Key, ctx: anytype, matches: anytype, path: *Path) Error!?Hit {
            const acc = self.model.accessor();
            if (try acc.isLeafId(id)) {
                var leaf = (try acc.loadLeaf(id)).?;
                defer acc.deinitLeaf(leaf);

                const n = try leaf.size();
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const mbr = try leaf.getMbr(i);
                    if (mbr.intersects(&query) and matches(ctx, mbr, try leaf.getValue(i))) {
                        return .{
                            .leaf_id = id,
                            .entry_idx = i,
                        };
                    }
                }
                return null;
            }
            var child_ids: [Max]Pid = undefined;
            var child_indices: [Max]usize = undefined;
            const child_count = blk: {
                var inode = (try acc.loadInode(id)).?;
                defer acc.deinitInode(inode);
                const n = try inode.size();
                var count: usize = 0;
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    if ((try inode.getMbr(i)).intersects(&query)) {
                        child_ids[count] = try inode.getChild(i);
                        child_indices[count] = i;
                        count += 1;
                    }
                }
                break :blk count;
            };
            for (child_ids[0..child_count], child_indices[0..child_count]) |child_id, child_idx| {
                path.push(.{ .id = id, .idx = child_idx });
                if (try self.findLeaf(child_id, query, ctx, matches, path)) |hit| {
                    return hit;
                }
                _ = path.pop();
            }
            return null;
        }

        fn condenseTree(self: *Self, path: *Path, leaf_id: Pid) Error!void {
            const acc = self.model.accessor();

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
                    try self.updateParentMbr(&parent, frame.idx, child_id);
                }

                const is_root = path.len == 0;
                if (!is_root and (try parent.size()) < min_fill) {
                    const plvl = try parent.getLevel();
                    const n = try parent.size();
                    var i: usize = 0;
                    while (i < n) : (i += 1) {
                        const subtree_id = try parent.getChild(i);
                        s_mbr[sn] = try self.nodeMbrOf(subtree_id);
                        s_id[sn] = subtree_id;
                        s_lvl[sn] = plvl - 1;
                        sn += 1;
                    }
                    remove_child = true;
                } else {
                    remove_child = false;
                }
                child_id = frame.id;
            }

            const empty_root_inode = blk: {
                if (try acc.isLeafId(child_id)) {
                    break :blk false;
                }
                var root = (try acc.loadInode(child_id)).?;
                defer acc.deinitInode(root);
                break :blk (try root.size()) == 0;
            };
            if (empty_root_inode) {
                try acc.setRoot(null);
                try acc.destroy(child_id);
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
                const OrphanEntry = struct {
                    mbr: Key,
                    value: ValueBuf,
                };
                var orphan_entries: [min_fill]OrphanEntry = undefined;
                var orphan_count: usize = 0;
                {
                    var leaf = (try acc.loadLeaf(olid)).?; // must be alive here
                    defer acc.deinitLeaf(leaf);
                    const n = try leaf.size();
                    var i: usize = 0;
                    while (i < n) : (i += 1) {
                        orphan_entries[i] = .{
                            .mbr = try leaf.getMbr(i),
                            .value = self.model.copyValueOut(try leaf.getValue(i)),
                        };
                        orphan_count += 1;
                    }
                }
                try acc.destroy(olid);
                for (orphan_entries[0..orphan_count]) |entry| {
                    try self.insertValue(
                        entry.mbr,
                        self.model.valueBufAsIn(&entry.value),
                        &ins_ctx,
                    );
                }
            }

            try self.drainReinserts(&ins_ctx);

            while (true) {
                const root = acc.getRoot() orelse {
                    break;
                };
                if (try acc.isLeafId(root)) break;
                const only: ?Pid = blk: {
                    var inode = (try acc.loadInode(root)).?;
                    defer acc.deinitInode(inode);
                    const size = try inode.size();
                    break :blk if (size == 1) try inode.getChild(0) else null;
                };
                if (only) |child| {
                    try acc.setRoot(child);
                    try acc.destroy(root);
                } else {
                    break;
                }
            }
        }

        fn insertSubtree(self: *Self, mbr: Key, child_id: Pid, target_level: usize, ctx: *InsertCtx) Error!void {
            const acc = self.model.accessor();

            const root = acc.getRoot() orelse {
                try acc.setRoot(child_id);
                return;
            };

            if ((try self.levelOf(root)) <= target_level) {
                var nr = try acc.createInode();
                errdefer acc.destroy(nr.id()) catch {};
                defer acc.deinitInode(nr);
                try nr.setLevel(target_level + 1);
                try nr.insertChild(ConfigT.makeInodeMbr(try self.nodeMbrOf(root)), root);
                try nr.insertChild(ConfigT.makeInodeMbr(mbr), child_id);
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
                    try inode.insertChild(ConfigT.makeInodeMbr(mbr), child_id);
                } else {
                    split = try self.splitInode(&inode, mbr, child_id);
                }
            }
            try self.adjustTree(&path, cur, split, ctx);
        }
    };
}
