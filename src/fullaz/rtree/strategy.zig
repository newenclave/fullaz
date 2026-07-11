const std = @import("std");
const helpers = @import("../contracts/interfaces.zig");

pub fn assertStrategy(comptime Strategy: type, comptime Key: type) void {
    if (!@hasDecl(Strategy, "wants_reinsert")) {
        @compileError("Strategy missing decl: wants_reinsert");
    }
    helpers.requiresFnSignature(Strategy, "chooseSubtree", fn ([]const Key, Key, bool) usize);
    helpers.requiresFnSignature(Strategy, "splitEntries", fn ([]const Key, usize, []u8) void);
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

            // select the childres with the least enlargement, breaking ties by area
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
