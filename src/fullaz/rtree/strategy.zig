const std = @import("std");
const helpers = @import("../contracts/interfaces.zig");

fn assertChooseStrategy(comptime Strategy: type, comptime Key: type) void {
    helpers.requiresFnSignature(Strategy, "chooseSubtree", fn ([]const Key, Key, bool) usize);
}

fn assertSplitStrategy(comptime Strategy: type, comptime Key: type) void {
    helpers.requiresFnSignature(Strategy, "splitEntries", fn ([]const Key, usize, []u8) void);
}

fn assertReinsertStrategy(comptime Strategy: type, comptime Key: type) void {
    if (!@hasDecl(Strategy, "wants_reinsert")) {
        @compileError("Strategy missing decl: wants_reinsert");
    }
    if (Strategy.wants_reinsert) {
        helpers.requiresFnSignature(Strategy, "reinsertOrder", fn ([]const Key, Key, []usize) void);
    }
}

pub fn assertStrategy(comptime Strategy: type, comptime Key: type) void {
    assertChooseStrategy(Strategy, Key);
    assertSplitStrategy(Strategy, Key);
    assertReinsertStrategy(Strategy, Key);
}

// the very original Guttman R-tree strategy, with quadratic split and no reinsert
pub fn GuttmanStrategy(comptime Key: type) type {
    const Coord = Key.Coord;

    return struct {
        pub const wants_reinsert = false;

        pub fn chooseSubtree(child_mbrs: []const Key, entry: Key, children_are_leaves: bool) usize {
            _ = children_are_leaves;
            var best: usize = 0;
            var best_enl = child_mbrs[0].enlargement(&entry);
            var best_area = child_mbrs[0].measure();

            // select the child with the least enlargement, breaking ties by area
            for (child_mbrs[1..], 1..) |mbr, i| {
                const enl = mbr.enlargement(&entry);
                const area = mbr.measure();
                if ((enl < best_enl) or (enl == best_enl and area < best_area)) {
                    best = i;
                    best_enl = enl;
                    best_area = area;
                }
            }
            return best;
        }

        pub fn splitEntries(mbrs: []const Key, min_fill: usize, assignment: []u8) void {
            const n = mbrs.len;
            const unassigned: u8 = 2;
            for (assignment) |*a| {
                a.* = unassigned;
            }

            var s0: usize = 0;
            var s1: usize = 1;
            var worst: Coord = waste(&mbrs[0], &mbrs[1]);
            var i: usize = 0;

            while (i < n) : (i += 1) {
                var j: usize = i + 1;
                while (j < n) : (j += 1) {
                    const d = waste(&mbrs[i], &mbrs[j]);
                    if (d > worst) {
                        worst = d;
                        s0 = i;
                        s1 = j;
                    }
                }
            }

            assignment[s0] = 0;
            assignment[s1] = 1;
            var mbr0 = mbrs[s0];
            var mbr1 = mbrs[s1];
            var cnt0: usize = 1;
            var cnt1: usize = 1;
            var assigned: usize = 2;

            while (assigned < n) {
                const remaining = n - assigned;
                if (cnt0 + remaining <= min_fill) {
                    assignRest(assignment, 0);
                    return;
                }
                if (cnt1 + remaining <= min_fill) {
                    assignRest(assignment, 1);
                    return;
                }

                var best_e: usize = 0;
                var best_pref: Coord = undefined;
                var best_d0: Coord = undefined;
                var best_d1: Coord = undefined;
                var found = false;
                var e: usize = 0;
                while (e < n) : (e += 1) {
                    if (assignment[e] != unassigned) {
                        continue;
                    }
                    const d0 = mbr0.enlargement(&mbrs[e]);
                    const d1 = mbr1.enlargement(&mbrs[e]);
                    const pref = if (d0 >= d1) d0 - d1 else d1 - d0;
                    if (!found or pref > best_pref) {
                        found = true;
                        best_pref = pref;
                        best_e = e;
                        best_d0 = d0;
                        best_d1 = d1;
                    }
                }

                if (pickGroup(best_d0, best_d1, mbr0, mbr1, cnt0, cnt1) == 0) {
                    assignment[best_e] = 0;
                    mbr0 = mbr0.merged(&mbrs[best_e]);
                    cnt0 += 1;
                } else {
                    assignment[best_e] = 1;
                    mbr1 = mbr1.merged(&mbrs[best_e]);
                    cnt1 += 1;
                }
                assigned += 1;
            }
        }

        pub fn reinsertOrder(_: []const Key, _: Key, _: []usize) void {}

        fn waste(a: *const Key, b: *const Key) Coord {
            return a.merged(b).measure() - a.measure() - b.measure();
        }

        fn assignRest(assignment: []u8, group: u8) void {
            for (assignment) |*a| {
                if (a.* == 2) {
                    a.* = group;
                }
            }
        }

        fn pickGroup(d0: Coord, d1: Coord, mbr0: Key, mbr1: Key, cnt0: usize, cnt1: usize) u8 {
            if (d0 < d1) {
                return 0;
            }
            if (d1 < d0) {
                return 1;
            }
            const a0 = mbr0.measure();
            const a1 = mbr1.measure();
            if (a0 < a1) {
                return 0;
            }
            if (a1 < a0) {
                return 1;
            }
            return if (cnt0 <= cnt1) 0 else 1;
        }
    };
}

// R*-tree strategy porting
pub fn RStarStrategy(comptime Key: type) type {
    const Coord = Key.Coord;
    const Point = Key.Point;
    const dims = Key.Dim;
    const split_cap = 512;

    return struct {
        pub const wants_reinsert = true;

        pub fn chooseSubtree(child_mbrs: []const Key, entry: Key, children_are_leaves: bool) usize {
            if (children_are_leaves) {
                return leastOverlap(child_mbrs, entry);
            }
            return leastEnlargement(child_mbrs, entry);
        }

        fn leastEnlargement(child_mbrs: []const Key, entry: Key) usize {
            var best: usize = 0;
            var b_enl = child_mbrs[0].enlargement(&entry);
            var b_area = child_mbrs[0].measure();
            for (child_mbrs[1..], 1..) |mbr, i| {
                const enl = mbr.enlargement(&entry);
                const area = mbr.measure();
                if (enl < b_enl or (enl == b_enl and area < b_area)) {
                    best = i;
                    b_enl = enl;
                    b_area = area;
                }
            }
            return best;
        }

        fn leastOverlap(child_mbrs: []const Key, entry: Key) usize {
            var best: usize = 0;
            var found = false;
            var b_ovl: Coord = undefined;
            var b_enl: Coord = undefined;
            var b_area: Coord = undefined;
            for (child_mbrs, 0..) |ci, i| {
                const expanded = ci.merged(&entry);
                var ovl: Coord = 0;
                for (child_mbrs, 0..) |cj, j| {
                    if (i == j) continue;
                    ovl += expanded.overlapMeasure(&cj) - ci.overlapMeasure(&cj);
                }
                const enl = ci.enlargement(&entry);
                const area = ci.measure();
                if (!found or less3(ovl, enl, area, b_ovl, b_enl, b_area)) {
                    found = true;
                    best = i;
                    b_ovl = ovl;
                    b_enl = enl;
                    b_area = area;
                }
            }
            return best;
        }

        pub fn splitEntries(mbrs: []const Key, min_fill: usize, assignment: []u8) void {
            const n = mbrs.len;

            var best_axis: usize = 0;
            var best_margin: Coord = undefined;
            var found = false;
            var d: usize = 0;
            while (d < dims) : (d += 1) {
                const s = axisMarginSum(mbrs, min_fill, d);
                if (!found or s < best_margin) {
                    found = true;
                    best_margin = s;
                    best_axis = d;
                }
            }

            var order: [split_cap]usize = undefined;
            sortByEdge(order[0..n], mbrs, best_axis, true);

            var best_k: usize = min_fill;
            var b_ovl: Coord = undefined;
            var b_measure: Coord = undefined;
            var kfound = false;
            var k: usize = min_fill;
            while (k <= (n - min_fill)) : (k += 1) {
                const g1 = bboxOf(mbrs, order[0..k]);
                const g2 = bboxOf(mbrs, order[k..n]);
                const ovl = g1.overlapMeasure(&g2);
                const measure = g1.measure() + g2.measure();
                if (!kfound or ovl < b_ovl or (ovl == b_ovl and measure < b_measure)) {
                    kfound = true;
                    best_k = k;
                    b_ovl = ovl;
                    b_measure = measure;
                }
            }

            for (order[0..n], 0..) |idx, i| {
                assignment[idx] = if (i < best_k) 0 else 1;
            }
        }

        pub fn reinsertOrder(mbrs: []const Key, node_mbr: Key, out: []usize) void {
            const c = node_mbr.center();
            for (out, 0..) |*o, i| {
                o.* = i;
            }
            const Ctx = struct {
                mbrs: []const Key,
                c: Point,
            };
            const cmp = struct {
                fn farther(ctx: Ctx, a: usize, b: usize) bool {
                    return distSq(ctx.mbrs[a].center(), ctx.c) > distSq(
                        ctx.mbrs[b].center(),
                        ctx.c,
                    );
                }
            }.farther;
            std.mem.sort(usize, out, Ctx{
                .mbrs = mbrs,
                .c = c,
            }, cmp);
        }

        fn axisMarginSum(mbrs: []const Key, min_fill: usize, axis: usize) Coord {
            const n = mbrs.len;
            var order: [split_cap]usize = undefined;
            var total: Coord = 0;
            sortByEdge(order[0..n], mbrs, axis, true);
            total += distMarginSum(mbrs, order[0..n], min_fill);
            sortByEdge(order[0..n], mbrs, axis, false);
            total += distMarginSum(mbrs, order[0..n], min_fill);
            return total;
        }

        fn distMarginSum(mbrs: []const Key, order: []const usize, min_fill: usize) Coord {
            const n = order.len;
            var sum: Coord = 0;
            var k: usize = min_fill;
            while (k <= n - min_fill) : (k += 1) {
                sum += bboxOf(mbrs, order[0..k]).perimeter() + bboxOf(mbrs, order[k..n]).perimeter();
            }
            return sum;
        }

        // the minimum box of the mbrs.
        fn bboxOf(mbrs: []const Key, order: []const usize) Key {
            var acc = mbrs[order[0]];
            for (order[1..]) |idx| {
                acc = acc.merged(&mbrs[idx]);
            }
            return acc;
        }

        fn sortByEdge(order: []usize, mbrs: []const Key, axis: usize, low: bool) void {
            for (order, 0..) |*o, i| {
                o.* = i;
            }
            const Ctx = struct {
                mbrs: []const Key,
                axis: usize,
                low: bool,
            };
            const cmp = struct {
                fn lt(ctx: Ctx, a: usize, b: usize) bool {
                    const ea = if (ctx.low) ctx.mbrs[a].low[ctx.axis] else ctx.mbrs[a].high[ctx.axis];
                    const eb = if (ctx.low) ctx.mbrs[b].low[ctx.axis] else ctx.mbrs[b].high[ctx.axis];
                    return ea < eb;
                }
            }.lt;
            std.mem.sort(usize, order, Ctx{
                .mbrs = mbrs,
                .axis = axis,
                .low = low,
            }, cmp);
        }

        fn distSq(p: Point, q: Point) Coord {
            var s: Coord = 0;
            var d: usize = 0;
            while (d < dims) : (d += 1) {
                const diff = p[d] - q[d];
                s += diff * diff;
            }
            return s;
        }

        fn less3(a: Coord, b: Coord, c: Coord, ba: Coord, bb: Coord, bc: Coord) bool {
            if (a != ba) {
                return a < ba;
            }
            if (b != bb) {
                return b < bb;
            }
            return c < bc;
        }
    };
}

pub fn HybridStrategyBase(
    comptime Key: type,
    comptime ChooseStrategyT: fn (comptime Key: type) type,
    comptime ReinsertStrategyT: fn (comptime Key: type) type,
    comptime SplitStrategyT: fn (comptime Key: type) type,
) type {
    comptime {
        assertChooseStrategy(ChooseStrategyT(Key), Key);
        assertReinsertStrategy(ReinsertStrategyT(Key), Key);
        assertSplitStrategy(SplitStrategyT(Key), Key);
    }

    return struct {
        pub const ChooseStrategy = ChooseStrategyT(Key);
        pub const ReinsertStrategy = ReinsertStrategyT(Key);
        pub const SplitStrategy = SplitStrategyT(Key);
        pub const wants_reinsert = ReinsertStrategy.wants_reinsert;

        pub fn chooseSubtree(child_mbrs: []const Key, entry: Key, children_are_leaves: bool) usize {
            return ChooseStrategy.chooseSubtree(child_mbrs, entry, children_are_leaves);
        }

        pub fn splitEntries(mbrs: []const Key, min_fill: usize, assignment: []u8) void {
            SplitStrategy.splitEntries(mbrs, min_fill, assignment);
        }

        pub fn reinsertOrder(mbrs: []const Key, node_mbr: Key, out: []usize) void {
            ReinsertStrategy.reinsertOrder(mbrs, node_mbr, out);
        }
    };
}

pub fn HybridStrategy(comptime Key: type) type {
    return HybridStrategyBase(
        Key,
        RStarStrategy,
        GuttmanStrategy,
        RStarStrategy,
    );
}
