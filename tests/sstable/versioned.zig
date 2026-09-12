const std = @import("std");
const fullaz = @import("fullaz");
const sstable = fullaz.sstable;
const Log = fullaz.device.MemoryLog(u64);
const allocator = std.testing.allocator;
const settings: sstable.Settings = .{
    .max_entries_per_coded_block = 2,
    .max_coded_block_bytes = 128,
    .data_page_bytes = 256,
    .index_page_bytes = 512,
    .max_key_bytes = 8,
    .max_value_bytes = 32,
};

fn compareBytes(_: void, a: []const u8, b: []const u8) fullaz.core.algorithm.Order {
    return switch (std.mem.order(u8, a, b)) {
        .lt => .lt,
        .eq => .eq,
        .gt => .gt,
    };
}

fn compareReverse(ctx: void, a: []const u8, b: []const u8) fullaz.core.algorithm.Order {
    return compareBytes(ctx, b, a);
}

fn Scratch(comptime ReaderT: type) type {
    return struct {
        value: ReaderT.ReadScratchType,

        fn init(reader: *ReaderT) !@This() {
            const requirements = reader.scratchRequirements();
            const data_page = try allocator.alloc(u8, requirements.data_page_bytes);
            errdefer allocator.free(data_page);
            const key = try allocator.alloc(u8, requirements.key_bytes);
            return .{ .value = .{ .data_page = data_page, .key = key } };
        }

        fn deinit(self: *@This()) void {
            allocator.free(self.value.key);
            allocator.free(self.value.data_page);
        }
    };
}

fn expectEntry(entry: anytype, value: []const u8, flags: sstable.EntryFlags, lsn: u64) !void {
    try std.testing.expectEqualSlices(u8, value, entry.value);
    try std.testing.expectEqual(flags, entry.metadata.flags);
    try std.testing.expectEqual(lsn, @as(u64, entry.metadata.lsn));
}

test "SSTable versioned seeks across blocks pages and index splits with both backends" {
    const Format = sstable.SstableFormatVersionedWithLsn(u64, u32, u32, u64, .little);
    const Writer = sstable.Writer(Format, Log, compareBytes, void);
    const Reader = sstable.Reader(Format, Log, compareBytes, void);
    const key_count = 64;
    const version_count = 24;
    var log = try Log.init(allocator);
    defer log.deinit();
    var writer = try Writer.init(allocator, &log, .{
        .entry_count = key_count * version_count + 2,
        .keys_count = key_count + 1,
        .comparator_id = 42,
        .settings = settings,
    }, {});
    defer writer.deinit();
    var key_buf: [8]u8 = undefined;
    var value_buf: [32]u8 = undefined;
    for (0..key_count) |i| {
        const key = try std.fmt.bufPrint(&key_buf, "k{d:0>4}", .{i});
        for (0..version_count) |j| {
            const lsn = (version_count - j) * 2;
            const tombstone = lsn == 16;
            const value = if (tombstone) "" else try std.fmt.bufPrint(&value_buf, "v{d}", .{lsn});
            try writer.addWithMetadata(key, value, .{
                .flags = if (tombstone) .tombstone else .value,
                .lsn = lsn,
            });
        }
    }
    try writer.addWithMetadata("z", "max", .{ .flags = .value, .lsn = std.math.maxInt(u64) });
    try writer.addWithMetadata("z", "zero", .{ .flags = .value, .lsn = 0 });
    try writer.finish();

    for ([_]sstable.IndexBackend{ .memory, .file }) |backend| {
        var reader = try Reader.init(allocator, &log, .{
            .comparator_id = 42,
            .index_backend = backend,
        }, {});
        defer reader.deinit();
        var scratch = try Scratch(Reader).init(&reader);
        defer scratch.deinit();
        try std.testing.expect(reader.footer.data_page_count > key_count);
        try std.testing.expect(reader.footer.index_page_count > 3);
        try std.testing.expectEqual(key_count * version_count + 2, reader.footer.entry_count);
        try std.testing.expectEqual(key_count + 1, reader.footer.keys_count);
        const bloom_params = fullaz.core.bloom.Bloom.calculateBloomParams(
            key_count + 1,
            settings.bloom_false_positive_rate,
        );
        try std.testing.expectEqual(bloom_params.bitset_bits, reader.footer.bloom_bit_count);
        try std.testing.expectEqual(bloom_params.hash_count, reader.footer.bloom_hash_count);
        try std.testing.expectEqual(@as(u64, 0), reader.footer.min_lsn);
        try std.testing.expectEqual(std.math.maxInt(u64), reader.footer.max_lsn);
        try std.testing.expectEqual(settings.max_key_bytes, reader.footer.settings.max_key_bytes);
        try std.testing.expect(scratch.value.key.len > settings.max_key_bytes);

        for (0..key_count) |i| {
            const key = try std.fmt.bufPrint(&key_buf, "k{d:0>4}", .{i});
            try expectEntry((try reader.find(key, &scratch.value)).?, "v48", .value, 48);
            for (0..version_count) |j| {
                const lsn: u64 = (version_count - j) * 2;
                const flags: sstable.EntryFlags = if (lsn == 16) .tombstone else .value;
                const value = if (lsn == 16) "" else try std.fmt.bufPrint(&value_buf, "v{d}", .{lsn});
                try expectEntry((try reader.findVersion(key, lsn, &scratch.value)).?, value, flags, lsn);
                try expectEntry((try reader.findAt(key, lsn, &scratch.value)).?, value, flags, lsn);
                try expectEntry((try reader.findAt(key, lsn + 1, &scratch.value)).?, value, flags, lsn);
                try std.testing.expect((try reader.findVersion(key, lsn + 1, &scratch.value)) == null);
                const bound = (try reader.lowerBound(key, lsn + 1, &scratch.value)).?;
                try std.testing.expectEqualSlices(u8, key, bound.key);
                try expectEntry(bound, value, flags, lsn);
            }
            try std.testing.expect((try reader.findAt(key, 1, &scratch.value)) == null);
            try std.testing.expect((try reader.findVersion(key, 0, &scratch.value)) == null);
            const next = (try reader.lowerBound(key, 1, &scratch.value)).?;
            var next_key_buf: [8]u8 = undefined;
            const next_key = if (i + 1 == key_count)
                "z"
            else
                try std.fmt.bufPrint(&next_key_buf, "k{d:0>4}", .{i + 1});
            try std.testing.expectEqualSlices(u8, next_key, next.key);
            try std.testing.expectEqual(
                if (i + 1 == key_count) std.math.maxInt(u64) else @as(u64, 48),
                next.metadata.lsn,
            );
        }

        // These absent keys precede the table, even when Bloom rejects them.
        const bloom = try fullaz.core.bitset.BitSet(u64, .little).initConst(
            reader.bloom_bytes,
            @intCast(reader.footer.bloom_bit_count),
        );
        var bloom_misses: usize = 0;
        for (0..32) |i| {
            const absent = try std.fmt.bufPrint(&key_buf, "j{d:0>4}", .{i});
            if (!fullaz.core.bloom.mightContain(&bloom, absent, reader.footer.bloom_hash_count)) {
                bloom_misses += 1;
            }
            try std.testing.expect((try reader.find(absent, &scratch.value)) == null);
            try std.testing.expect((try reader.findAt(absent, 20, &scratch.value)) == null);
            const bound = (try reader.lowerBound(absent, 20, &scratch.value)).?;
            try std.testing.expectEqualSlices(u8, "k0000", bound.key);
            try expectEntry(bound, "v48", .value, 48);
        }
        try std.testing.expect(bloom_misses > 0);
        try expectEntry((try reader.find("z", &scratch.value)).?, "max", .value, std.math.maxInt(u64));
        try expectEntry((try reader.findAt("z", std.math.maxInt(u64) - 1, &scratch.value)).?, "zero", .value, 0);
        try expectEntry((try reader.findVersion("z", 0, &scratch.value)).?, "zero", .value, 0);
        try std.testing.expect((try reader.lowerBound("zz", 0, &scratch.value)) == null);
        try std.testing.expect((try reader.findAt("zz", std.math.maxInt(u64), &scratch.value)) == null);

        var iterator = try reader.iterator(&scratch.value);
        for (0..key_count) |i| {
            const key = try std.fmt.bufPrint(&key_buf, "k{d:0>4}", .{i});
            for (0..version_count) |j| {
                const lsn: u64 = (version_count - j) * 2;
                const entry = (try iterator.next()).?;
                try std.testing.expectEqualSlices(u8, key, entry.key);
                const value = if (lsn == 16) "" else try std.fmt.bufPrint(&value_buf, "v{d}", .{lsn});
                try expectEntry(entry, value, if (lsn == 16) .tombstone else .value, lsn);
            }
        }
        const newest = (try iterator.next()).?;
        try std.testing.expectEqualSlices(u8, "z", newest.key);
        try expectEntry(newest, "max", .value, std.math.maxInt(u64));
        const oldest = (try iterator.next()).?;
        try std.testing.expectEqualSlices(u8, "z", oldest.key);
        try expectEntry(oldest, "zero", .value, 0);
        try std.testing.expect((try iterator.next()) == null);
    }
}

test "SSTable versioned reverse comparator binary prefix and empty keys across wire types" {
    @setEvalBranchQuota(10000);
    inline for (.{ u32, u64 }) |LsnT| {
        inline for (.{ .little, .big }) |endian| {
            const Format = sstable.SstableFormatVersionedWithLsn(u64, u32, u32, LsnT, endian);
            const Writer = sstable.Writer(Format, Log, compareReverse, void);
            const Reader = sstable.Reader(Format, Log, compareReverse, void);
            const keys = [_][]const u8{ "\xff", "a\xff", "a\x00", "a", "\x00\xff", "\x00", "" };
            const lsns = [_]LsnT{ std.math.maxInt(LsnT), 0x0102_0304, 0 };
            var log = try Log.init(allocator);
            defer log.deinit();
            var writer = try Writer.init(allocator, &log, .{
                .entry_count = keys.len * lsns.len,
                .comparator_id = 99,
                .settings = settings,
            }, {});
            defer writer.deinit();
            for (keys) |key| {
                for (lsns, 0..) |lsn, i| {
                    try writer.addWithMetadata(key, if (i == 0) "" else "live", .{
                        .flags = if (i == 0) .tombstone else .value,
                        .lsn = lsn,
                    });
                }
            }
            try writer.finish();
            try std.testing.expectEqual(keys.len, writer.keys_count);
            for ([_]sstable.IndexBackend{ .memory, .file }) |backend| {
                var reader = try Reader.init(allocator, &log, .{
                    .comparator_id = 99,
                    .index_backend = backend,
                }, {});
                defer reader.deinit();
                try std.testing.expectEqual(keys.len, reader.footer.keys_count);
                var scratch = try Scratch(Reader).init(&reader);
                defer scratch.deinit();
                for (keys) |key| {
                    try expectEntry((try reader.find(key, &scratch.value)).?, "", .tombstone, lsns[0]);
                    try expectEntry((try reader.findAt(key, lsns[0] - 1, &scratch.value)).?, "live", .value, lsns[1]);
                    try expectEntry((try reader.findAt(key, 0, &scratch.value)).?, "live", .value, 0);
                    for (lsns, 0..) |lsn, i| {
                        try expectEntry(
                            (try reader.findVersion(key, lsn, &scratch.value)).?,
                            if (i == 0) "" else "live",
                            if (i == 0) .tombstone else .value,
                            lsn,
                        );
                    }
                }
                try std.testing.expect((try reader.findAt("b", lsns[0], &scratch.value)) == null);
                const bound = (try reader.lowerBound("b", 0, &scratch.value)).?;
                try std.testing.expectEqualSlices(u8, "a\xff", bound.key);
                try expectEntry(bound, "", .tombstone, lsns[0]);
                var iterator = try reader.iterator(&scratch.value);
                for (keys) |key| {
                    for (lsns, 0..) |lsn, i| {
                        const entry = (try iterator.next()).?;
                        try std.testing.expectEqualSlices(u8, key, entry.key);
                        try expectEntry(entry, if (i == 0) "" else "live", if (i == 0) .tombstone else .value, lsn);
                    }
                }
                try std.testing.expect((try iterator.next()) == null);
            }
        }
    }
}

test "SSTable versioned writer enforces composite order and user key limits" {
    const Format = sstable.SstableFormatVersionedWithLsn(u64, u32, u32, u64, .little);
    const Writer = sstable.Writer(Format, Log, compareBytes, void);
    const Reader = sstable.Reader(Format, Log, compareBytes, void);
    var log = try Log.init(allocator);
    defer log.deinit();
    var writer = try Writer.init(allocator, &log, .{
        .entry_count = 3,
        .comparator_id = 42,
        .settings = settings,
    }, {});
    defer writer.deinit();
    try std.testing.expectEqual(@as(usize, 0), writer.keys_count);
    try writer.addWithMetadata("12345678", "first", .{ .flags = .value, .lsn = 10 });
    try std.testing.expectEqual(@as(usize, 1), writer.entry_count);
    try std.testing.expectEqual(@as(usize, 1), writer.keys_count);
    const bloom_before = try allocator.dupe(u8, writer.bloom_bytes);
    defer allocator.free(bloom_before);
    try std.testing.expectError(error.DuplicateKey, writer.addWithMetadata(
        "12345678",
        "",
        .{ .flags = .tombstone, .lsn = 10 },
    ));
    try std.testing.expectEqual(@as(usize, 1), writer.entry_count);
    try std.testing.expectEqual(@as(usize, 1), writer.keys_count);
    try std.testing.expectError(error.UnorderedKey, writer.addWithMetadata(
        "12345678",
        "bad",
        .{ .flags = .value, .lsn = 11 },
    ));
    try std.testing.expectError(error.UnorderedKey, writer.addWithMetadata(
        "0",
        "bad",
        .{ .flags = .value, .lsn = 0 },
    ));
    try std.testing.expectError(error.KeyTooLarge, writer.addWithMetadata(
        "123456789",
        "bad",
        .{ .flags = .value, .lsn = 9 },
    ));
    try std.testing.expectEqual(@as(usize, 1), writer.entry_count);
    try std.testing.expectEqual(@as(usize, 1), writer.keys_count);
    try std.testing.expectEqualSlices(u8, bloom_before, writer.bloom_bytes);
    try writer.addWithMetadata("12345678", "old", .{ .flags = .value, .lsn = 9 });
    try std.testing.expectEqual(@as(usize, 2), writer.entry_count);
    try std.testing.expectEqual(@as(usize, 1), writer.keys_count);
    try std.testing.expectEqualSlices(u8, bloom_before, writer.bloom_bytes);
    try writer.addWithMetadata("2", "new key", .{ .flags = .value, .lsn = 100 });
    try std.testing.expectEqual(@as(usize, 3), writer.entry_count);
    try std.testing.expectEqual(@as(usize, 2), writer.keys_count);
    try writer.finish();
    try std.testing.expectEqual(@as(usize, 3), writer.entry_count);
    try std.testing.expectEqual(@as(usize, 2), writer.keys_count);
    var reader = try Reader.init(allocator, &log, .{ .comparator_id = 42 }, {});
    defer reader.deinit();
    try std.testing.expectEqual(@as(u64, 3), reader.footer.entry_count);
    try std.testing.expectEqual(@as(u64, 2), reader.footer.keys_count);
    var scratch = try Scratch(Reader).init(&reader);
    defer scratch.deinit();
    try expectEntry((try reader.find("12345678", &scratch.value)).?, "first", .value, 10);
    try expectEntry((try reader.findVersion("12345678", 9, &scratch.value)).?, "old", .value, 9);
    try expectEntry((try reader.find("2", &scratch.value)).?, "new key", .value, 100);
    var short = scratch.value;
    short.key = short.key[0 .. short.key.len - 1];
    try std.testing.expectError(error.BadScratch, reader.findVersion("12345678", 10, &short));
    try std.testing.expectError(error.BadScratch, reader.findAt("12345678", 10, &short));
    try std.testing.expectError(error.BadScratch, reader.lowerBound("12345678", 10, &short));
    try std.testing.expectError(error.BadScratch, reader.iterator(&short));
}

test "SSTable versioned Bloom key hints do not change actual counts or hide versions" {
    const Format = sstable.SstableFormatVersionedWithLsn(u64, u32, u32, u64, .little);
    const Writer = sstable.Writer(Format, Log, compareBytes, void);
    const Reader = sstable.Reader(Format, Log, compareBytes, void);
    const keys = [_][]const u8{ "", "a", "z" };
    const versions = 24;
    const entry_count = keys.len * versions;
    for ([_]?usize{ null, 1, keys.len, 256 }) |hint| {
        var log = try Log.init(allocator);
        defer log.deinit();
        var writer = try Writer.init(allocator, &log, .{
            .entry_count = entry_count,
            .keys_count = hint,
            .comparator_id = 42,
            .settings = settings,
        }, {});
        defer writer.deinit();
        const params = fullaz.core.bloom.Bloom.calculateBloomParams(
            hint orelse entry_count,
            settings.bloom_false_positive_rate,
        );
        try std.testing.expectEqual(params.bitset_bits, writer.bloom_bit_count);
        try std.testing.expectEqual(params.hash_count, writer.bloom_hash_count);
        try std.testing.expectEqual(@as(usize, 0), writer.keys_count);
        for (keys, 0..) |key, i| {
            for (0..versions) |j| {
                const lsn = versions - j;
                if (i == 1) {
                    try writer.addTombstone(key, lsn);
                } else {
                    try writer.addWithMetadata(key, "value", .{ .flags = .value, .lsn = lsn });
                }
                try std.testing.expectEqual(i + 1, writer.keys_count);
                try std.testing.expectEqual(i * versions + j + 1, writer.entry_count);
            }
        }
        try writer.finish();
        try std.testing.expectEqual(keys.len, writer.keys_count);
        try std.testing.expectEqual(entry_count, writer.entry_count);
        var reader = try Reader.init(allocator, &log, .{ .comparator_id = 42 }, {});
        defer reader.deinit();
        try std.testing.expectEqual(keys.len, reader.footer.keys_count);
        try std.testing.expectEqual(entry_count, reader.footer.entry_count);
        try std.testing.expectEqual(params.bitset_bits, reader.footer.bloom_bit_count);
        try std.testing.expectEqual(params.hash_count, reader.footer.bloom_hash_count);
        var scratch = try Scratch(Reader).init(&reader);
        defer scratch.deinit();
        for (keys, 0..) |key, i| {
            const flags: sstable.EntryFlags = if (i == 1) .tombstone else .value;
            const value = if (i == 1) "" else "value";
            try expectEntry((try reader.find(key, &scratch.value)).?, value, flags, versions);
            for (0..versions) |j| {
                const lsn = versions - j;
                try expectEntry((try reader.findVersion(key, lsn, &scratch.value)).?, value, flags, lsn);
                try expectEntry((try reader.findAt(key, lsn, &scratch.value)).?, value, flags, lsn);
            }
        }
    }
    var log = try Log.init(allocator);
    defer log.deinit();
    try std.testing.expectError(error.InvalidSettings, Writer.init(allocator, &log, .{
        .entry_count = entry_count,
        .keys_count = 0,
        .comparator_id = 42,
        .settings = settings,
    }, {}));
    try std.testing.expectEqual(@as(u64, 0), log.size());
}

test "SSTable versioned merger preserves versions and first input ties across sizing modes" {
    @setEvalBranchQuota(10000);
    const Format = sstable.SstableFormatVersionedWithLsn(u64, u32, u32, u32, .big);
    const Writer = sstable.Writer(Format, Log, compareBytes, void);
    const Reader = sstable.Reader(Format, Log, compareBytes, void);
    const Merger = sstable.Merger(Format, Log, compareBytes, void);
    const Input = struct { key: []const u8, value: []const u8, lsn: u32, flags: sstable.EntryFlags = .value };
    const sources = [_][]const Input{
        &.{
            .{ .key = "", .value = "", .lsn = 3, .flags = .tombstone },
            .{ .key = "", .value = "", .lsn = 1, .flags = .tombstone },
            .{ .key = "a", .value = "", .lsn = 9, .flags = .tombstone },
            .{ .key = "a", .value = "first", .lsn = 5 },
            .{ .key = "c", .value = "c0", .lsn = 0 },
        },
        &.{
            .{ .key = "", .value = "", .lsn = 2, .flags = .tombstone },
            .{ .key = "a", .value = "loser", .lsn = 9 },
            .{ .key = "a", .value = "a7", .lsn = 7 },
            .{ .key = "a", .value = "", .lsn = 5, .flags = .tombstone },
            .{ .key = "b", .value = "b4", .lsn = 4 },
        },
        &.{
            .{ .key = "a", .value = "a10", .lsn = 10 },
            .{ .key = "a", .value = "a0", .lsn = 0 },
            .{ .key = "b", .value = "", .lsn = 3, .flags = .tombstone },
        },
    };
    const expected = [_]Input{
        .{ .key = "", .value = "", .lsn = 3, .flags = .tombstone },
        .{ .key = "", .value = "", .lsn = 2, .flags = .tombstone },
        .{ .key = "", .value = "", .lsn = 1, .flags = .tombstone },
        .{ .key = "a", .value = "a10", .lsn = 10 },
        .{ .key = "a", .value = "", .lsn = 9, .flags = .tombstone },
        .{ .key = "a", .value = "a7", .lsn = 7 },
        .{ .key = "a", .value = "first", .lsn = 5 },
        .{ .key = "a", .value = "a0", .lsn = 0 },
        .{ .key = "b", .value = "b4", .lsn = 4 },
        .{ .key = "b", .value = "", .lsn = 3, .flags = .tombstone },
        .{ .key = "c", .value = "c0", .lsn = 0 },
    };
    var logs: [sources.len]Log = undefined;
    var readers: [sources.len]Reader = undefined;
    var inputs: [sources.len]*Reader = undefined;
    var initialized: usize = 0;
    defer for (0..initialized) |i| {
        readers[i].deinit();
        logs[i].deinit();
    };
    for (sources, 0..) |entries, i| {
        logs[i] = try Log.init(allocator);
        errdefer logs[i].deinit();
        var writer = try Writer.init(allocator, &logs[i], .{
            .entry_count = entries.len,
            .comparator_id = 42,
            .settings = settings,
        }, {});
        defer writer.deinit();
        for (entries) |entry| {
            try writer.addWithMetadata(entry.key, entry.value, .{ .flags = entry.flags, .lsn = entry.lsn });
        }
        try writer.finish();
        readers[i] = try Reader.init(allocator, &logs[i], .{
            .comparator_id = 42,
            .index_backend = if (i == 1) .file else .memory,
        }, {});
        inputs[i] = &readers[i];
        initialized += 1;
        try std.testing.expectEqual(entries.len, readers[i].footer.entry_count);
        try std.testing.expectEqual(@as(u64, if (i == 2) 2 else 3), readers[i].footer.keys_count);
    }
    const cases = [_]struct {
        strategy: ?Merger.EntryCountStrategy = null,
        keys_count: ?usize = null,
        bloom_keys: usize,
    }{
        .{ .bloom_keys = 8 },
        .{ .strategy = .exact_two_pass, .bloom_keys = 4 },
        .{ .strategy = .{ .estimate = 1 }, .bloom_keys = 1 },
        .{ .strategy = .{ .estimate = 100 }, .bloom_keys = 100 },
        .{ .strategy = .{ .estimate = 1 }, .keys_count = 32, .bloom_keys = 32 },
        .{ .strategy = .exact_two_pass, .keys_count = 1, .bloom_keys = 1 },
        .{ .keys_count = 32, .bloom_keys = 32 },
    };
    for (cases) |case| {
        var output_log = try Log.init(allocator);
        defer output_log.deinit();
        var options: Merger.Options = .{
            .comparator_id = 42,
            .settings = settings,
            .keys_count = case.keys_count,
        };
        if (case.strategy) |strategy| {
            options.entry_count_strategy = strategy;
        }
        try Merger.run(allocator, &inputs, &output_log, options, {});
        var output = try Reader.init(allocator, &output_log, .{ .comparator_id = 42 }, {});
        defer output.deinit();
        var scratch = try Scratch(Reader).init(&output);
        defer scratch.deinit();
        try std.testing.expectEqual(expected.len, output.footer.entry_count);
        try std.testing.expectEqual(@as(u64, 4), output.footer.keys_count);
        const bloom_params = fullaz.core.bloom.Bloom.calculateBloomParams(
            case.bloom_keys,
            settings.bloom_false_positive_rate,
        );
        try std.testing.expectEqual(bloom_params.bitset_bits, output.footer.bloom_bit_count);
        try std.testing.expectEqual(bloom_params.hash_count, output.footer.bloom_hash_count);
        try std.testing.expectEqual(@as(u32, 0), output.footer.min_lsn);
        try std.testing.expectEqual(@as(u32, 10), output.footer.max_lsn);
        var iterator = try output.iterator(&scratch.value);
        for (expected) |want| {
            const entry = (try iterator.next()).?;
            try std.testing.expectEqualSlices(u8, want.key, entry.key);
            try expectEntry(entry, want.value, want.flags, want.lsn);
        }
        try std.testing.expect((try iterator.next()) == null);
        for (expected, 0..) |want, i| {
            if (i == 0 or !std.mem.eql(u8, expected[i - 1].key, want.key)) {
                try expectEntry(
                    (try output.find(want.key, &scratch.value)).?,
                    want.value,
                    want.flags,
                    want.lsn,
                );
            }
            try expectEntry(
                (try output.findVersion(want.key, want.lsn, &scratch.value)).?,
                want.value,
                want.flags,
                want.lsn,
            );
        }
        try expectEntry((try output.findAt("a", 9, &scratch.value)).?, "", .tombstone, 9);
        try expectEntry((try output.findAt("a", 8, &scratch.value)).?, "a7", .value, 7);
        try expectEntry((try output.find("", &scratch.value)).?, "", .tombstone, 3);
    }
    var rejected_log = try Log.init(allocator);
    defer rejected_log.deinit();
    try std.testing.expectError(error.InvalidSettings, Merger.run(allocator, &inputs, &rejected_log, .{
        .comparator_id = 42,
        .settings = settings,
        .drop_winning_tombstones = true,
    }, {}));
    try std.testing.expectEqual(@as(u64, 0), rejected_log.size());
    try std.testing.expectError(error.InvalidSettings, Merger.run(allocator, &inputs, &rejected_log, .{
        .comparator_id = 42,
        .settings = settings,
        .keys_count = 0,
    }, {}));
    try std.testing.expectEqual(@as(u64, 0), rejected_log.size());
}

test "SSTable versioned and legacy footer trailer and reader cross reject" {
    @setEvalBranchQuota(10000);
    const Versioned = sstable.SstableFormatVersionedWithLsn(u64, u32, u32, u64, .little);
    const Legacy = sstable.SstableFormatWithLsn(u64, u32, u32, u64, .little);
    inline for (.{ Versioned, Legacy }, .{ Legacy, Versioned }, .{ 4, 2 }) |Format, Other, version| {
        const Writer = sstable.Writer(Format, Log, compareBytes, void);
        const WrongReader = sstable.Reader(Other, Log, compareBytes, void);
        const Footer = sstable.Footer(Format);
        const WrongFooter = sstable.Footer(Other);
        var log = try Log.init(allocator);
        defer log.deinit();
        var writer = try Writer.init(allocator, &log, .{
            .entry_count = 1,
            .comparator_id = 42,
            .settings = settings,
        }, {});
        defer writer.deinit();
        try writer.addWithMetadata("key", "value", .{ .flags = .value, .lsn = 7 });
        try writer.finish();
        var trailer: [@sizeOf(Footer.Trailer)]u8 = undefined;
        try log.readAt(log.size() - trailer.len, &trailer);
        const trailer_view: *const Footer.Trailer = @ptrCast(&trailer);
        try std.testing.expectEqual(version, trailer_view.version.get());
        _ = try Footer.validateTrailer(&trailer);
        try std.testing.expectError(error.BadTrailer, WrongFooter.validateTrailer(&trailer));
        var footer_bytes: [settings.index_page_bytes]u8 = undefined;
        const footer_offset = log.size() - trailer.len - footer_bytes.len;
        try log.readAt(footer_offset, &footer_bytes);
        const footer = try Footer.View(true).init(&footer_bytes);
        try std.testing.expectEqual(version, footer.header().version.get());
        const info = try footer.validate(footer_offset);
        try std.testing.expectEqual(@as(u64, 1), info.keys_count);
        const wrong_footer = try WrongFooter.View(true).init(&footer_bytes);
        try std.testing.expectError(error.BadVersion, wrong_footer.validate(footer_offset));
        try std.testing.expectError(error.BadTrailer, WrongReader.init(
            allocator,
            &log,
            .{ .comparator_id = 42 },
            {},
        ));
    }
}

test "SSTable versioned footer validates distinct key counts and v4 layout" {
    inline for (.{ .little, .big }) |endian| {
        const Format = sstable.SstableFormatVersionedWithLsn(u64, u32, u32, u64, endian);
        const Footer = sstable.Footer(Format);
        const LegacyFooter = sstable.Footer(sstable.SstableFormatWithLsn(u64, u32, u32, u64, endian));
        const PackedOffset = fullaz.core.packed_int.PackedInt(Format.Offset, endian);
        try std.testing.expect(@FieldType(Footer.Header, "keys_count") == PackedOffset);
        try std.testing.expectEqual(
            @offsetOf(Footer.Header, "entry_count") + @sizeOf(PackedOffset),
            @offsetOf(Footer.Header, "keys_count"),
        );
        try std.testing.expectEqual(
            @sizeOf(LegacyFooter.Header) + @sizeOf(PackedOffset),
            @sizeOf(Footer.Header),
        );
        var bytes: [settings.index_page_bytes]u8 = undefined;
        var view = try Footer.View(false).init(&bytes);
        const info: Footer.Info = .{
            .comparator_id = 42,
            .entry_count = 3,
            .keys_count = 2,
            .data_offset = 0,
            .data_length = 128,
            .data_page_count = 1,
            .bloom_offset = 128,
            .bloom_length = 8,
            .bloom_bit_count = 64,
            .bloom_hash_count = 3,
            .index_offset = 136,
            .index_page_size = bytes.len,
            .index_page_count = 1,
            .index_root_page_id = 0,
            .settings = settings,
        };
        const footer_offset = info.index_offset + bytes.len;
        for ([_]u64{ 1, 2, 3 }) |count| {
            var valid = info;
            valid.keys_count = count;
            try view.format(valid);
            const restored = try view.validate(footer_offset);
            try std.testing.expectEqual(count, restored.keys_count);
            try std.testing.expectEqual(info.entry_count, restored.entry_count);
        }
        for ([_]u64{ 0, info.entry_count + 1 }) |count| {
            var invalid = info;
            invalid.keys_count = count;
            try std.testing.expectError(error.BadSettings, view.format(invalid));
            try view.format(info);
            view.headerMut().keys_count.set(count);
            // Recompute the checksum so count validation is exercised.
            const checksum_offset = @offsetOf(Footer.Header, "checksum");
            var crc = std.hash.Crc32.init();
            crc.update(bytes[0..checksum_offset]);
            crc.update(bytes[checksum_offset + @sizeOf(@FieldType(Footer.Header, "checksum")) ..]);
            view.headerMut().checksum.set(crc.final());
            try std.testing.expectError(error.BadSettings, view.validate(footer_offset));
        }
        try view.format(info);
        try std.testing.expectEqual(@as(u16, 4), view.header().version.get());
        view.headerMut().version.set(3);
        try std.testing.expectError(error.BadVersion, view.validate(footer_offset));
        var trailer: [@sizeOf(Footer.Trailer)]u8 = undefined;
        try Footer.formatTrailer(&trailer, bytes.len);
        const trailer_view: *Footer.Trailer = @ptrCast(&trailer);
        try std.testing.expectEqual(@as(u16, 4), trailer_view.version.get());
        trailer_view.version.set(3);
        try std.testing.expectError(error.BadTrailer, Footer.validateTrailer(&trailer));
    }
}

test "SSTable versioned reader rejects a different LSN width" {
    @setEvalBranchQuota(10000);
    inline for (.{ u32, u64 }, .{ u64, u32 }) |LsnT, OtherLsnT| {
        const Format = sstable.SstableFormatVersionedWithLsn(u64, u32, u32, LsnT, .little);
        const Other = sstable.SstableFormatVersionedWithLsn(u64, u32, u32, OtherLsnT, .little);
        const Writer = sstable.Writer(Format, Log, compareBytes, void);
        const WrongReader = sstable.Reader(Other, Log, compareBytes, void);
        var log = try Log.init(allocator);
        defer log.deinit();
        var writer = try Writer.init(allocator, &log, .{
            .entry_count = 1,
            .comparator_id = 42,
            .settings = settings,
        }, {});
        defer writer.deinit();
        try writer.addWithMetadata("key", "value", .{ .flags = .value, .lsn = 7 });
        try writer.finish();
        try std.testing.expectError(error.BadHeaderSize, WrongReader.init(
            allocator,
            &log,
            .{ .comparator_id = 42 },
            {},
        ));
    }
}

fn expectCorruptVersionedRecord(comptime corruption: enum { truncated_key, mismatched_lsn }) !void {
    @setEvalBranchQuota(10000);
    const Format = sstable.SstableFormatVersionedWithLsn(u64, u32, u32, u64, .little);
    const Writer = sstable.Writer(Format, Log, compareBytes, void);
    const Reader = sstable.Reader(Format, Log, compareBytes, void);
    const DataPage = sstable.DataPage(Format);
    const EntryMetadata = sstable.EntryMetadata(Format);
    const PackedLsn = fullaz.core.packed_int.PackedInt(Format.Lsn, Format.Endian);
    const BlockView = fullaz.codec.bounded_buffer.MemoryBlockView(u8);
    const CodedBlock = fullaz.codec.front_coded_block.FrontCodedBlockWithMetadata(
        Format.DataIndex,
        Format.DataIndex,
        Format.DataIndex,
        fullaz.codec.bounded_buffer.MemoryBlockWriter(u8),
        BlockView,
        Format.Endian,
        true,
        compareBytes,
        void,
        EntryMetadata.byte_len,
    );
    var log = try Log.init(allocator);
    defer log.deinit();
    var writer = try Writer.init(allocator, &log, .{
        .entry_count = 1,
        .comparator_id = 42,
        .settings = settings,
    }, {});
    defer writer.deinit();
    try writer.addWithMetadata("", "payload", .{ .flags = .value, .lsn = 7 });
    try writer.finish();
    const info = blk: {
        var reader = try Reader.init(allocator, &log, .{ .comparator_id = 42 }, {});
        defer reader.deinit();
        var scratch = try Scratch(Reader).init(&reader);
        defer scratch.deinit();
        try expectEntry((try reader.findVersion("", 7, &scratch.value)).?, "payload", .value, 7);
        break :blk reader.footer;
    };
    try std.testing.expectEqual(@as(u32, 1), info.data_page_count);
    const image = try allocator.alloc(u8, @intCast(log.size()));
    defer allocator.free(image);
    try log.readAt(0, image);
    const data_offset: usize = @intCast(info.data_offset);
    const data_length: usize = @intCast(info.data_length);
    const page = try DataPage.View(false).init(image[data_offset..][0..data_length]);
    try page.validate();
    try std.testing.expectEqual(@as(usize, 1), page.blockCount());
    const fence = try allocator.dupe(u8, try page.fenceKey(0));
    defer allocator.free(fence);
    const coded = @constCast(try page.codedBlock(0));
    const header: *CodedBlock.Header = @ptrCast(coded.ptr);
    const record = coded[@sizeOf(CodedBlock.Header)..];
    const entry_header: *CodedBlock.EntryHeader = @ptrCast(record.ptr);
    try std.testing.expectEqual(@as(u32, 0), entry_header.shared_len.get());
    try std.testing.expectEqual(@sizeOf(PackedLsn), entry_header.suffix_len.get());
    switch (corruption) {
        .truncated_key => {
            // Keep the record size and metadata position valid for the codec.
            entry_header.suffix_len.set(@sizeOf(PackedLsn) - 1);
            entry_header.value_len.set(entry_header.value_len.get() + 1);
            header.max_key_len.set(entry_header.suffix_len.get());
        },
        .mismatched_lsn => {
            const suffix_lsn: *PackedLsn = @ptrCast(record[@sizeOf(CodedBlock.EntryHeader)..].ptr);
            suffix_lsn.set(8);
        },
    }
    try page.validate();
    try std.testing.expectEqualSlices(u8, fence, try page.fenceKey(0));
    var coded_reader = try CodedBlock.Reader.init(BlockView.init(coded));
    defer coded_reader.deinit();
    var key_buf: [settings.max_key_bytes + @sizeOf(PackedLsn)]u8 = undefined;
    var coded_iterator = try coded_reader.iterator(&key_buf);
    defer coded_iterator.deinit();
    const metadata = try EntryMetadata.fromBytes(try coded_iterator.metadata());
    try std.testing.expectEqual(@as(u64, 7), metadata.lsn);
    try std.testing.expectEqual(.value, metadata.flags);
    try std.testing.expectEqual(
        if (corruption == .truncated_key) @sizeOf(PackedLsn) - 1 else @sizeOf(PackedLsn),
        coded_iterator.scratchKey().len,
    );
    try log.reset();
    try log.append(image);

    for ([_]sstable.IndexBackend{ .memory, .file }) |backend| {
        var reader = try Reader.init(allocator, &log, .{
            .comparator_id = 42,
            .index_backend = backend,
        }, {});
        defer reader.deinit();
        var scratch = try Scratch(Reader).init(&reader);
        defer scratch.deinit();
        const expected_error = if (corruption == .truncated_key) error.BadData else error.InvalidMetadata;
        var iterator = try reader.iterator(&scratch.value);
        try std.testing.expectError(expected_error, iterator.next());
        try std.testing.expectError(expected_error, reader.findAt("", 7, &scratch.value));
        try std.testing.expectError(expected_error, reader.findVersion("", 7, &scratch.value));
    }
}

test "SSTable versioned rejects a truncated internal key in a coded record" {
    try expectCorruptVersionedRecord(.truncated_key);
}

test "SSTable versioned rejects a coded record LSN that disagrees with metadata" {
    try expectCorruptVersionedRecord(.mismatched_lsn);
}

test "SSTable versioned rejects truncated loaded index leaf keys and inode separators" {
    const Format = sstable.SstableFormatVersionedWithLsn(u64, u32, u32, u64, .little);
    const Writer = sstable.Writer(Format, Log, compareBytes, void);
    const Reader = sstable.Reader(Format, Log, compareBytes, void);
    const IndexView = fullaz.bpt.models.paged.View(Format.PageId, u16, .little, false);
    const index_settings: fullaz.bpt.models.paged.Settings = .{};
    const short_key = [_]u8{0} ** (@sizeOf(Format.Lsn) - 1);

    for ([_]bool{ false, true }) |corrupt_inode| {
        const entry_count: usize = if (corrupt_inode) 128 else 1;
        var log = try Log.init(allocator);
        defer log.deinit();
        var writer = try Writer.init(allocator, &log, .{
            .entry_count = entry_count,
            .comparator_id = 42,
            .settings = settings,
        }, {});
        defer writer.deinit();
        var key_buf: [8]u8 = undefined;
        for (0..entry_count) |i| {
            const key = try std.fmt.bufPrint(&key_buf, "k{d:0>4}", .{i});
            try writer.addWithMetadata(key, "payload", .{ .flags = .value, .lsn = 7 });
        }
        try writer.finish();
        const info = blk: {
            var reader = try Reader.init(allocator, &log, .{ .comparator_id = 42 }, {});
            defer reader.deinit();
            break :blk reader.footer;
        };
        const image = try allocator.alloc(u8, @intCast(log.size()));
        defer allocator.free(image);
        try log.readAt(0, image);
        const root_offset = @as(usize, @intCast(info.index_offset)) +
            @as(usize, info.index_root_page_id) * settings.index_page_bytes;
        const root_bytes = image[root_offset..][0..settings.index_page_bytes];
        const page = IndexView.PageViewType.init(root_bytes);
        try page.validateTyped();
        const max_key_bytes = try Format.internalKeyBytes(settings.max_key_bytes);
        if (corrupt_inode) {
            try std.testing.expectEqual(index_settings.inode_page_kind, page.header().kind.get());
            var inode = IndexView.InodeSubheaderView.init(root_bytes);
            const child = (try inode.get(0)).child;
            var slots = try inode.slotsDirMut();
            const record = try slots.resizeGet(0, @sizeOf(IndexView.InodeSlotHeader) + short_key.len);
            @memcpy(record[@sizeOf(IndexView.InodeSlotHeader)..], &short_key);
            try inode.validatePage(info.index_root_page_id, index_settings.inode_page_kind, max_key_bytes);
            try std.testing.expectEqual(child, (try inode.get(0)).child);
            try std.testing.expectEqualSlices(u8, &short_key, (try inode.get(0)).key);
        } else {
            try std.testing.expectEqual(@as(u32, 1), info.index_page_count);
            try std.testing.expectEqual(index_settings.leaf_page_kind, page.header().kind.get());
            var leaf = IndexView.LeafSubheaderView.init(root_bytes);
            var location: [2 * @sizeOf(Format.Offset)]u8 = undefined;
            @memcpy(&location, (try leaf.get(0)).value);
            try leaf.formatPage(index_settings.leaf_page_kind, info.index_root_page_id, 0);
            try leaf.insert(0, &short_key, &location);
            try leaf.validatePage(info.index_root_page_id, index_settings.leaf_page_kind, max_key_bytes, location.len);
        }
        try log.reset();
        try log.append(image);

        for ([_]sstable.IndexBackend{ .memory, .file }) |backend| {
            var reader = try Reader.init(allocator, &log, .{
                .comparator_id = 42,
                .index_backend = backend,
            }, {});
            defer reader.deinit();
            var scratch = try Scratch(Reader).init(&reader);
            defer scratch.deinit();
            try std.testing.expectError(error.BadIndex, reader.find("k0000", &scratch.value));
            try std.testing.expectError(error.BadIndex, reader.findAt("k0000", 7, &scratch.value));
            try std.testing.expectError(error.BadIndex, reader.findVersion("k0000", 7, &scratch.value));
            try std.testing.expectError(error.BadIndex, reader.lowerBound("k0000", 7, &scratch.value));

            var iterator = try reader.iterator(&scratch.value);
            for (0..entry_count) |i| {
                const key = try std.fmt.bufPrint(&key_buf, "k{d:0>4}", .{i});
                const entry = (try iterator.next()).?;
                try std.testing.expectEqualSlices(u8, key, entry.key);
                try expectEntry(entry, "payload", .value, 7);
            }
            try std.testing.expect((try iterator.next()) == null);
        }
    }
}
