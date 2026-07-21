const std = @import("std");
const fullaz = @import("fullaz");
const models = fullaz.lsm.models;
const strategy = fullaz.lsm.strategy;
const flush_policy = fullaz.lsm.flush_policy;
const value = fullaz.lsm.value;
const Lsm = fullaz.lsm.Lsm;
const SortedVector = fullaz.lsm.memtable.SortedVector;

const ValueCodec = value.Value(u64, .native);
const MemoryModel = models.MemoryModel(SortedVector);
const Engine = Lsm(MemoryModel, strategy.NaiveMergeAllStrategy, flush_policy.ThresholdFlushPolicy);
const SizeTieredEngine = Lsm(MemoryModel, strategy.SizeTieredStrategy, flush_policy.ThresholdFlushPolicy);

const never_flush = flush_policy.ThresholdFlushPolicy.init(null, null);

test "LSM engine: put then get, overwrite, missing key" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = Engine.init(&model, allocator, never_flush);
    defer lsm.deinit();

    try lsm.put("a", "1");
    try lsm.put("b", "2");

    try std.testing.expectEqualSlices(u8, "1", (try lsm.get("a")).?);
    try std.testing.expectEqualSlices(u8, "2", (try lsm.get("b")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try lsm.get("missing"));

    try lsm.put("a", "one");
    try std.testing.expectEqualSlices(u8, "one", (try lsm.get("a")).?);
}

test "LSM engine: delete makes a key invisible" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = Engine.init(&model, allocator, never_flush);
    defer lsm.deinit();

    try lsm.put("a", "1");
    try std.testing.expectEqualSlices(u8, "1", (try lsm.get("a")).?);

    try lsm.delete("a");
    try std.testing.expectEqual(@as(?[]const u8, null), try lsm.get("a"));

    try std.testing.expectEqual(@as(?[]const u8, null), try lsm.get("never-existed"));
}

test "LSM engine: put after delete makes the key visible again" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = Engine.init(&model, allocator, never_flush);
    defer lsm.deinit();

    try lsm.put("a", "1");
    try lsm.delete("a");
    try lsm.put("a", "2");

    try std.testing.expectEqualSlices(u8, "2", (try lsm.get("a")).?);
}

test "LSM engine: flushing an empty memtable is a no-op" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = Engine.init(&model, allocator, never_flush);
    defer lsm.deinit();

    try lsm.flush();
    try std.testing.expectEqual(@as(usize, 0), model.getAccessor().runCount());
}

test "LSM engine: flush moves data into a run, get() still finds it" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = Engine.init(&model, allocator, never_flush);
    defer lsm.deinit();

    try lsm.put("a", "1");
    try lsm.put("b", "2");

    try lsm.flush();
    try std.testing.expectEqual(@as(usize, 1), model.getAccessor().runCount());

    try std.testing.expectEqualSlices(u8, "1", (try lsm.get("a")).?);
    try std.testing.expectEqualSlices(u8, "2", (try lsm.get("b")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try lsm.get("missing"));
}

test "LSM engine: a tombstone written before flush still hides the key afterward" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = Engine.init(&model, allocator, never_flush);
    defer lsm.deinit();

    try lsm.put("a", "1");
    try lsm.delete("a");

    try lsm.flush();

    try std.testing.expectEqual(@as(?[]const u8, null), try lsm.get("a"));
}

test "LSM engine: byte-size threshold triggers an automatic flush" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    // Each 1-byte-payload put is key(1) + encodedLen(1) = 1 + (1 + 9) = 11
    // bytes (header = 1 tag byte + 8-byte u64 lsn). One put alone (11) must
    // stay under the threshold; two puts together (22) must cross it.
    var lsm = Engine.init(&model, allocator, flush_policy.ThresholdFlushPolicy.init(15, null));
    defer lsm.deinit();

    try lsm.put("a", "1");
    try std.testing.expectEqual(@as(usize, 0), model.getAccessor().runCount());

    try lsm.put("b", "2");
    try std.testing.expectEqual(@as(usize, 1), model.getAccessor().runCount());

    try std.testing.expectEqualSlices(u8, "1", (try lsm.get("a")).?);
    try std.testing.expectEqualSlices(u8, "2", (try lsm.get("b")).?);
}

test "LSM engine: count threshold triggers an automatic flush" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = Engine.init(&model, allocator, flush_policy.ThresholdFlushPolicy.init(null, 2));
    defer lsm.deinit();

    try lsm.put("a", "1");
    try std.testing.expectEqual(@as(usize, 0), model.getAccessor().runCount());

    try lsm.put("b", "2");
    try std.testing.expectEqual(@as(usize, 1), model.getAccessor().runCount());

    try std.testing.expectEqualSlices(u8, "1", (try lsm.get("a")).?);
    try std.testing.expectEqualSlices(u8, "2", (try lsm.get("b")).?);
}

test "LSM engine: delete also goes through maybeFlush" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = Engine.init(&model, allocator, flush_policy.ThresholdFlushPolicy.init(null, 1));
    defer lsm.deinit();

    try lsm.delete("a");

    try std.testing.expectEqual(@as(usize, 1), model.getAccessor().runCount());
    try std.testing.expectEqual(@as(?[]const u8, null), try lsm.get("a"));
}

test "LSM engine: a newer run shadows an older run for the same key" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = Engine.init(&model, allocator, never_flush);
    defer lsm.deinit();

    try lsm.put("a", "old");
    try lsm.flush();

    try lsm.put("a", "new");
    try lsm.flush();

    // flush() now auto-compacts (M14); with NaiveMergeAllStrategy, two runs
    // never survive side by side -- they merge back down to one immediately.
    try std.testing.expectEqual(@as(usize, 1), model.getAccessor().runCount());
    try std.testing.expectEqualSlices(u8, "new", (try lsm.get("a")).?);
}

test "LSM engine: compact() merges overlapping runs, drops the tombstone, keeps ascending order" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = Engine.init(&model, allocator, never_flush);
    defer lsm.deinit();

    try lsm.put("a", "1");
    try lsm.put("b", "2");
    try lsm.flush();
    try std.testing.expectEqual(@as(usize, 1), model.getAccessor().runCount());

    try lsm.put("b", "20");
    try lsm.put("c", "3");
    try lsm.flush();
    // NaiveMergeAllStrategy auto-compacts on every flush that leaves >= 2 runs.
    try std.testing.expectEqual(@as(usize, 1), model.getAccessor().runCount());

    try lsm.delete("a");
    try lsm.put("c", "30");
    try lsm.flush();
    try std.testing.expectEqual(@as(usize, 1), model.getAccessor().runCount());

    try std.testing.expectEqual(@as(?[]const u8, null), try lsm.get("a"));
    try std.testing.expectEqualSlices(u8, "20", (try lsm.get("b")).?);
    try std.testing.expectEqualSlices(u8, "30", (try lsm.get("c")).?);

    // Inspect the single surviving run directly: ascending, deduped, and
    // the "a" tombstone is gone entirely (not just shadowed) since a
    // NaiveMergeAllStrategy merge always reaches the oldest run.
    const acc = model.getAccessor();
    const run = (try acc.loadRun(acc.runIdAt(0))).?;
    defer acc.closeRun(run);

    var it = try run.iterator();
    defer it.deinit();

    const expect_keys = [_][]const u8{ "b", "c" };
    var i: usize = 0;
    while (try it.peek()) |e| : (try it.advance()) {
        try std.testing.expectEqualSlices(u8, expect_keys[i], e.key);
        i += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), i);
}

test "LSM engine: SizeTieredStrategy only merges the qualifying contiguous tier, leaving an outlier run untouched and its tombstone preserved" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = SizeTieredEngine.init(&model, allocator, never_flush);
    defer lsm.deinit();

    // encodedLen(n) = n + 9 (1 tag byte + 8-byte u64 lsn header).
    //
    // Oldest, "big" run: one key with a long payload -> tier 2
    // (growth_factor=4: byte_size = 1 + encodedLen(20) = 1 + 29 = 30, in [16,64)).
    try lsm.put("w", "OLDVALUE_OLDVALUE_12");
    try lsm.flush();

    // Three small tier-1 runs (byte_size = 1 + encodedLen(1) = 1 + 10 = 11, in [4,16)).
    try lsm.put("a", "1");
    try lsm.flush();
    try lsm.put("b", "2");
    try lsm.flush();
    try lsm.put("c", "3");
    try lsm.flush();

    // Fourth small run: a tombstone for "w" (byte_size = 1 + encodedLen(0)
    // = 1 + 9 = 10, still tier 1). Newest-first order is now:
    // [tombstone(w), c, b, a, big(w=OLDVALUE...)] -- four tier-1 runs
    // followed by one tier-2 outlier. min_tier_runs=4, so this flush's
    // auto-compact() merges exactly the four tier-1 runs.
    try lsm.delete("w");
    try lsm.flush();

    const acc = model.getAccessor();
    try std.testing.expectEqual(@as(usize, 2), acc.runCount());

    try std.testing.expectEqualSlices(u8, "1", (try lsm.get("a")).?);
    try std.testing.expectEqualSlices(u8, "2", (try lsm.get("b")).?);
    try std.testing.expectEqualSlices(u8, "3", (try lsm.get("c")).?);
    // "w" must stay hidden -- if the tombstone had been wrongly dropped,
    // this would incorrectly resurface the old value still sitting in the
    // untouched, older "big" run.
    try std.testing.expectEqual(@as(?[]const u8, null), try lsm.get("w"));

    // Confirm directly: the tombstone for "w" physically survived the
    // merge (the merge span did not reach the oldest run, so it must be
    // carried through verbatim, not dropped).
    const merged_run = (try acc.loadRun(acc.runIdAt(0))).?;
    defer acc.closeRun(merged_run);

    var found_w_tombstone = false;
    var it = try merged_run.iterator();
    defer it.deinit();
    while (try it.peek()) |e| : (try it.advance()) {
        if (std.mem.eql(u8, e.key, "w")) {
            try std.testing.expect(value.isTombstone(e.value));
            found_w_tombstone = true;
        }
    }
    try std.testing.expect(found_w_tombstone);
}

test "LSM engine: SizeTieredStrategy merges same-tier runs even when a different-tier run sits between them" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = SizeTieredEngine.init(&model, allocator, never_flush);
    defer lsm.deinit();

    // Newest-first after four flushes: [c, z(outlier), b, a] -- three
    // tier-1 runs (a,b,c) with the tier-2 outlier "z" sandwiched between
    // b and c, not at either end. Before this fix, SizeTieredStrategy could
    // only combine a maximal CONTIGUOUS same-tier block, so a/b (below the
    // outlier) and c (above it) could never merge into one run together.
    try lsm.put("a", "1");
    try lsm.flush();
    try lsm.put("b", "2");
    try lsm.flush();
    try lsm.put("z", "OLDVALUE_OLDVALUE_12");
    try lsm.flush();
    try lsm.put("c", "3");
    try lsm.flush();

    const acc = model.getAccessor();
    try std.testing.expectEqual(@as(usize, 4), acc.runCount());

    // Fourth tier-1 flush: min_tier_runs=4 is now reached across a
    // non-contiguous set (a, b, c, d), skipping the tier-2 outlier "z".
    try lsm.put("d", "4");
    try lsm.flush();

    try std.testing.expectEqual(@as(usize, 2), acc.runCount());

    try std.testing.expectEqualSlices(u8, "1", (try lsm.get("a")).?);
    try std.testing.expectEqualSlices(u8, "2", (try lsm.get("b")).?);
    try std.testing.expectEqualSlices(u8, "3", (try lsm.get("c")).?);
    try std.testing.expectEqualSlices(u8, "4", (try lsm.get("d")).?);
    try std.testing.expectEqualSlices(u8, "OLDVALUE_OLDVALUE_12", (try lsm.get("z")).?);
}

test "LSM engine: get() finds the true newest value even when its run is not newest-first in run_order" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    // SizeTieredEngine, not Engine: NaiveMergeAllStrategy would auto-merge
    // everything back together on every flush, undoing the setup below
    // before this test gets to inspect it. Three runs, all a similar small
    // size, never reach min_tier_runs=4, so nothing auto-compacts here.
    var lsm = SizeTieredEngine.init(&model, allocator, never_flush);
    defer lsm.deinit();

    try lsm.put("k", "early");
    try lsm.flush();

    try lsm.put("k", "fresh");
    try lsm.flush();

    try lsm.put("filler", "x");
    try lsm.flush();

    const acc = model.getAccessor();
    try std.testing.expectEqual(@as(usize, 3), acc.runCount());

    // Newest-first right now: [filler, fresh(k), early(k)]. Simulate a
    // non-contiguous compaction that merges "filler" and "early" directly,
    // skipping "fresh" in between -- carrying early's STALE "k" straight
    // through unchanged, exactly like a real merge would (nothing in the
    // runs actually being merged shadows it).
    const filler_id = acc.runIdAt(0);
    const early_id = acc.runIdAt(2);

    var merged_source = try SortedVector.init(allocator);
    defer merged_source.deinit();
    {
        const filler_run = (try acc.loadRun(filler_id)).?;
        defer acc.closeRun(filler_run);
        try merged_source.put("filler", (try filler_run.get("filler")).?);

        const early_run = (try acc.loadRun(early_id)).?;
        defer acc.closeRun(early_run);
        try merged_source.put("k", (try early_run.get("k")).?);
    }
    var it = try merged_source.iterator();
    const merged_id = try acc.buildRun(&it);
    it.deinit();

    try acc.publish(&.{ filler_id, early_id }, merged_id);

    // run_order is now [merged, fresh] -- "merged" sits BEFORE "fresh" even
    // though it only holds the stale "k". get() must compare lsn, not
    // position, to still find "fresh".
    try std.testing.expectEqual(@as(usize, 2), acc.runCount());
    try std.testing.expectEqualSlices(u8, "fresh", (try lsm.get("k")).?);
    try std.testing.expectEqualSlices(u8, "x", (try lsm.get("filler")).?);
}

test "LSM engine: Iterator satisfies the KvCursor contract" {
    comptime models.interfaces.assertKvCursor(SizeTieredEngine.Iterator);
}

test "LSM engine: iterator() gives an ascending, deduped, tombstone-free view across the memtable and multiple runs" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = SizeTieredEngine.init(&model, allocator, never_flush);
    defer lsm.deinit();

    // Two runs, deliberately different tiers so SizeTieredStrategy never
    // merges them (a length-1 block never reaches min_tier_runs=4).
    try lsm.put("a", "1");
    try lsm.flush();
    try lsm.put("w", "OLDVALUE_OLDVALUE_12");
    try lsm.flush();
    try std.testing.expectEqual(@as(usize, 2), model.getAccessor().runCount());

    // Still in the active memtable: a tombstone shadowing run0's "a", plus
    // two brand-new keys.
    try lsm.delete("a");
    try lsm.put("b", "2");
    try lsm.put("m", "5");

    var it = try lsm.iterator();
    defer it.deinit();

    const expect_keys = [_][]const u8{ "b", "m", "w" };
    const expect_vals = [_][]const u8{ "2", "5", "OLDVALUE_OLDVALUE_12" };
    var i: usize = 0;
    while (try it.peek()) |e| : (try it.advance()) {
        try std.testing.expectEqualSlices(u8, expect_keys[i], e.key);
        try std.testing.expectEqualSlices(u8, expect_vals[i], ValueCodec.payloadOf(e.value));
        i += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), i);
}

test "LSM engine: seek() positions at the first key >= target across the merged view" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = SizeTieredEngine.init(&model, allocator, never_flush);
    defer lsm.deinit();

    try lsm.put("a", "1");
    try lsm.flush();
    try lsm.put("w", "OLDVALUE_OLDVALUE_12");
    try lsm.flush();
    try std.testing.expectEqual(@as(usize, 2), model.getAccessor().runCount());

    try lsm.put("b", "2");
    try lsm.put("m", "5");

    var it = try lsm.seek("c");
    defer it.deinit();

    const expect_keys = [_][]const u8{ "m", "w" };
    var i: usize = 0;
    while (try it.peek()) |e| : (try it.advance()) {
        try std.testing.expectEqualSlices(u8, expect_keys[i], e.key);
        i += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), i);
}

test "LSM engine: lsn values strictly increase across sequential puts" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = Engine.init(&model, allocator, never_flush);
    defer lsm.deinit();

    // Keys chosen so key order matches write order, so walking the merged
    // iterator also walks puts in the order they were written.
    try lsm.put("a", "1");
    try lsm.put("b", "2");
    try lsm.put("c", "3");

    var it = try lsm.iterator();
    defer it.deinit();

    var last_lsn: ?u64 = null;
    var count: usize = 0;
    while (try it.peek()) |e| : (try it.advance()) {
        if (last_lsn) |prev| {
            try std.testing.expect(e.lsn > prev);
        }
        last_lsn = e.lsn;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "LSM engine: overwriting a key produces a strictly larger lsn" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = Engine.init(&model, allocator, never_flush);
    defer lsm.deinit();

    try lsm.put("a", "1");
    var it1 = try lsm.iterator();
    const first_lsn = (try it1.peek()).?.lsn;
    it1.deinit();

    try lsm.put("a", "2");
    var it2 = try lsm.iterator();
    defer it2.deinit();
    const second_lsn = (try it2.peek()).?.lsn;

    try std.testing.expect(second_lsn > first_lsn);
}

test "LSM engine: delete also consumes an lsn from the counter" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = Engine.init(&model, allocator, never_flush);
    defer lsm.deinit();

    try lsm.put("a", "1"); // lsn 0
    try lsm.delete("a"); // lsn 1, tombstoned -> dropped by iterator()
    try lsm.put("b", "2"); // lsn 2, if delete() really consumed lsn 1

    var it = try lsm.iterator();
    defer it.deinit();
    const e = (try it.peek()).?;
    try std.testing.expectEqualSlices(u8, "b", e.key);
    try std.testing.expectEqual(@as(u64, 2), e.lsn);
}

const SoakOp = union(enum) {
    put: struct { key: []const u8, value: []const u8 },
    delete: []const u8,
    flush,
};

// Deliberately small single-entry-ish flushes: with SizeTieredStrategy this
// naturally accumulates same-tier runs and triggers a real partial merge
// partway through, not just at the very end.
const soak_ops = [_]SoakOp{
    .{ .put = .{ .key = "a", .value = "1" } },
    .{ .put = .{ .key = "b", .value = "2" } },
    .{ .put = .{ .key = "c", .value = "3" } },
    .flush,
    .{ .put = .{ .key = "a", .value = "10" } },
    .{ .put = .{ .key = "d", .value = "4" } },
    .flush,
    .{ .delete = "b" },
    .{ .put = .{ .key = "e", .value = "5" } },
    .flush,
    .{ .put = .{ .key = "c", .value = "30" } },
    .{ .delete = "e" },
    .flush,
    .{ .put = .{ .key = "f", .value = "6" } },
    .{ .put = .{ .key = "g", .value = "7" } },
    .{ .put = .{ .key = "a", .value = "100" } },
    .flush,
    .{ .delete = "c" },
    .flush,
    .{ .put = .{ .key = "b", .value = "200" } },
    .flush,
};

const soak_keys = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g" };

// Drives lsm through ops while keeping an independent oracle (plain
// key -> current value map, absence = deleted-or-never-written) and
// checks every tracked key against lsm.get() after every single op, not
// just at the end.
fn runSoak(lsm: anytype, allocator: std.mem.Allocator, ops: []const SoakOp, all_keys: []const []const u8) !void {
    var oracle = std.StringHashMap([]const u8).init(allocator);
    defer oracle.deinit();

    for (ops) |op| {
        switch (op) {
            .put => |p| {
                try lsm.put(p.key, p.value);
                try oracle.put(p.key, p.value);
            },
            .delete => |k| {
                try lsm.delete(k);
                _ = oracle.remove(k);
            },
            .flush => {
                try lsm.flush();
            },
        }

        for (all_keys) |key| {
            const expected = oracle.get(key);
            const actual = try lsm.get(key);
            if (expected) |v| {
                try std.testing.expect(actual != null);
                try std.testing.expectEqualSlices(u8, v, actual.?);
            } else {
                try std.testing.expectEqual(@as(?[]const u8, null), actual);
            }
        }
    }
}

test "LSM engine: multi-round soak test with NaiveMergeAllStrategy" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = Engine.init(&model, allocator, never_flush);
    defer lsm.deinit();

    try runSoak(&lsm, allocator, &soak_ops, &soak_keys);
}

test "LSM engine: multi-round soak test with SizeTieredStrategy" {
    const allocator = std.testing.allocator;

    var model = try MemoryModel.init(allocator);
    defer model.deinit();

    var lsm = SizeTieredEngine.init(&model, allocator, never_flush);
    defer lsm.deinit();

    try runSoak(&lsm, allocator, &soak_ops, &soak_keys);
}
