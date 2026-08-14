const std = @import("std");
const sstable = @import("fullaz").sstable;

test "SSTable format records wire types" {
    const Format = sstable.SstableFormat(u64, u32, u32, .little);
    const ShortLsnFormat = sstable.SstableFormatWithLsn(u64, u32, u32, u16, .little);
    const MediumLsnFormat = sstable.SstableFormatWithLsn(u64, u32, u32, u32, .little);

    try std.testing.expect(Format.Offset == u64);
    try std.testing.expect(Format.PageId == u32);
    try std.testing.expect(Format.DataIndex == u32);
    try std.testing.expect(Format.Lsn == u64);
    try std.testing.expect(Format.Endian == .little);
    try std.testing.expect(ShortLsnFormat.Lsn == u16);
    try std.testing.expect(MediumLsnFormat.Lsn == u32);
}

test "SSTable entry metadata validates flags" {
    const Format = sstable.SstableFormatWithLsn(u64, u32, u32, u16, .little);
    const EntryMetadata = sstable.EntryMetadata(Format);
    var bytes: [EntryMetadata.byte_len]u8 = undefined;
    bytes[0] = 2;
    @memset(bytes[1..], 0);

    try std.testing.expectError(error.InvalidMetadata, EntryMetadata.fromBytes(&bytes));
}

test "SSTable entry metadata preserves an LSN" {
    const Format = sstable.SstableFormatWithLsn(u64, u32, u32, u32, .little);
    const EntryMetadata = sstable.EntryMetadata(Format);
    const metadata = EntryMetadata{
        .flags = .tombstone,
        .lsn = 0x0102_0304,
    };
    const bytes = metadata.toBytes();
    const restored = try EntryMetadata.fromBytes(&bytes);

    try std.testing.expectEqual(.tombstone, restored.flags);
    try std.testing.expectEqual(@as(u32, 0x0102_0304), restored.lsn);
}

test "SSTable reader and writer contracts accept minimal interfaces" {
    const Writer = struct {
        pub const Error = error{};

        pub fn add(_: *@This(), _: []const u8, _: []const u8) Error!void {}
        pub fn finish(_: *@This()) Error!void {}
        pub fn deinit(_: *@This()) void {}
    };
    const Reader = struct {
        pub const Error = error{};
        pub const ReadScratchType = struct {};
        pub const Entry = struct { value: []const u8 };

        pub fn find(_: *@This(), _: []const u8, _: *ReadScratchType) Error!?Entry {
            return null;
        }
        pub fn deinit(_: *@This()) void {}
    };

    comptime sstable.interfaces.assertWriter(Writer);
    comptime sstable.interfaces.assertReader(Reader);
}

test "SSTable footer formats and validates its regions" {
    const Format = sstable.SstableFormat(u64, u32, u32, .little);
    const Footer = sstable.Footer(Format);
    var bytes: [4096]u8 = undefined;
    var view = try Footer.View(false).init(&bytes);
    const info = Footer.Info{
        .comparator_id = 17,
        .entry_count = 128,
        .data_offset = 0,
        .data_length = 8192,
        .data_page_count = 2,
        .bloom_offset = 8192,
        .bloom_length = 64,
        .bloom_bit_count = 512,
        .bloom_hash_count = 3,
        .index_offset = 8256,
        .index_page_size = bytes.len,
        .index_page_count = 2,
        .index_root_page_id = 1,
        .settings = .{
            .index_page_bytes = bytes.len,
        },
    };
    const footer_offset = info.index_offset + @as(u64, bytes.len) * info.index_page_count;

    try view.format(info);
    const actual = try Footer.View(true).init(&bytes);
    const restored = try actual.validate(footer_offset);

    try std.testing.expectEqual(info.comparator_id, restored.comparator_id);
    try std.testing.expectEqual(info.entry_count, restored.entry_count);
    try std.testing.expectEqual(info.index_root_page_id, restored.index_root_page_id);
    try std.testing.expectEqual(info.settings, restored.settings);

    var bad_info = info;
    bad_info.min_lsn = 2;
    bad_info.max_lsn = 1;
    try std.testing.expectError(error.BadSettings, view.format(bad_info));
}

test "SSTable footer rejects a corrupt checksum" {
    const Format = sstable.SstableFormat(u64, u32, u32, .little);
    const Footer = sstable.Footer(Format);
    var bytes: [1024]u8 = undefined;
    var view = try Footer.View(false).init(&bytes);
    const info = Footer.Info{
        .comparator_id = 17,
        .entry_count = 1,
        .data_offset = 0,
        .data_length = 1,
        .data_page_count = 1,
        .bloom_offset = 1,
        .bloom_length = 1,
        .bloom_bit_count = 8,
        .bloom_hash_count = 1,
        .index_offset = 2,
        .index_page_size = bytes.len,
        .index_page_count = 1,
        .index_root_page_id = 0,
        .settings = .{
            .index_page_bytes = bytes.len,
        },
    };
    const footer_offset = info.index_offset + bytes.len;

    try view.format(info);
    bytes[bytes.len - 1] ^= 1;
    const actual = try Footer.View(true).init(&bytes);
    try std.testing.expectError(error.BadChecksum, actual.validate(footer_offset));
}

test "SSTable footer rejects version 1" {
    const Format = sstable.SstableFormat(u64, u32, u32, .little);
    const Footer = sstable.Footer(Format);
    var bytes: [1024]u8 = undefined;
    var view = try Footer.View(false).init(&bytes);
    const info = Footer.Info{
        .comparator_id = 17,
        .entry_count = 1,
        .data_offset = 0,
        .data_length = 1,
        .data_page_count = 1,
        .bloom_offset = 1,
        .bloom_length = 1,
        .bloom_bit_count = 8,
        .bloom_hash_count = 1,
        .index_offset = 2,
        .index_page_size = bytes.len,
        .index_page_count = 1,
        .index_root_page_id = 0,
        .settings = .{
            .index_page_bytes = bytes.len,
        },
    };
    const footer_offset = info.index_offset + bytes.len;

    try view.format(info);
    view.headerMut().version.set(1);
    try std.testing.expectError(error.BadVersion, view.validate(footer_offset));

    var trailer: [@sizeOf(Footer.Trailer)]u8 = undefined;
    try Footer.formatTrailer(&trailer, bytes.len);
    const trailer_view: *Footer.Trailer = @ptrCast(trailer[0..].ptr);
    trailer_view.version.set(1);
    try std.testing.expectError(error.BadTrailer, Footer.validateTrailer(&trailer));
}

fn compareBytes(_: void, a: []const u8, b: []const u8) @import("fullaz").core.algorithm.Order {
    return switch (std.mem.order(u8, a, b)) {
        .lt => .lt,
        .eq => .eq,
        .gt => .gt,
    };
}

const MergeFormat = sstable.SstableFormatWithLsn(u64, u32, u32, u16, .little);
const MergeLog = @import("fullaz").device.MemoryLog(u64);
const MergeWriter = sstable.Writer(MergeFormat, MergeLog, compareBytes, void);
const MergeReader = sstable.Reader(MergeFormat, MergeLog, compareBytes, void);
const MergeMerger = sstable.Merger(MergeFormat, MergeLog, compareBytes, void);
const merge_source_settings: sstable.Settings = .{
    .max_entries_per_coded_block = 2,
    .max_coded_block_bytes = 128,
    .data_page_bytes = 512,
    .index_page_bytes = 512,
    .max_key_bytes = 32,
    .max_value_bytes = 32,
};
const merge_output_settings: sstable.Settings = .{
    .max_entries_per_coded_block = 3,
    .max_coded_block_bytes = 128,
    .data_page_bytes = 256,
    .index_page_bytes = 1024,
    .max_key_bytes = 64,
    .max_value_bytes = 64,
};

const MergeInput = struct {
    key: []const u8,
    value: []const u8,
    flags: sstable.EntryFlags,
    lsn: u16,
};

fn createMergeReader(
    allocator: std.mem.Allocator,
    log: *MergeLog,
    entries: []const MergeInput,
) !MergeReader {
    var writer = try MergeWriter.init(
        allocator,
        log,
        .{
            .entry_count = entries.len,
            .comparator_id = 42,
            .settings = merge_source_settings,
        },
        {},
    );
    defer writer.deinit();
    for (entries) |entry| {
        try writer.addWithMetadata(entry.key, entry.value, .{
            .flags = entry.flags,
            .lsn = entry.lsn,
        });
    }
    try writer.finish();
    return MergeReader.init(
        allocator,
        log,
        .{
            .comparator_id = 42,
            .index_backend = .memory,
        },
        {},
    );
}

fn expectMergeEntry(
    reader: *MergeReader,
    scratch: *MergeReader.ReadScratchType,
    key: []const u8,
    value: []const u8,
    flags: sstable.EntryFlags,
    lsn: u16,
) !void {
    const entry = (try reader.find(key, scratch)).?;
    try std.testing.expectEqualSlices(u8, value, entry.value);
    try std.testing.expectEqual(flags, entry.metadata.flags);
    try std.testing.expectEqual(lsn, entry.metadata.lsn);
}

test "SSTable merger selects versions across all sizing strategies" {
    const newest_entries = [_]MergeInput{
        .{ .key = "ant", .value = "newer", .flags = .value, .lsn = 5 },
        .{ .key = "cat", .value = "", .flags = .tombstone, .lsn = 11 },
        .{ .key = "dog", .value = "newest-tie", .flags = .value, .lsn = 9 },
        .{ .key = "fox", .value = "f", .flags = .value, .lsn = 2 },
    };
    const middle_entries = [_]MergeInput{
        .{ .key = "ant", .value = "highest-lsn", .flags = .value, .lsn = 7 },
        .{ .key = "bat", .value = "b", .flags = .value, .lsn = 4 },
        .{ .key = "cat", .value = "old-live", .flags = .value, .lsn = 10 },
        .{ .key = "dog", .value = "older-tie", .flags = .value, .lsn = 9 },
    };
    const oldest_entries = [_]MergeInput{
        .{ .key = "cat", .value = "oldest", .flags = .value, .lsn = 1 },
        .{ .key = "eel", .value = "e", .flags = .value, .lsn = 3 },
    };

    var newest_log = try MergeLog.init(std.testing.allocator);
    defer newest_log.deinit();
    var middle_log = try MergeLog.init(std.testing.allocator);
    defer middle_log.deinit();
    var oldest_log = try MergeLog.init(std.testing.allocator);
    defer oldest_log.deinit();
    var newest = try createMergeReader(std.testing.allocator, &newest_log, &newest_entries);
    defer newest.deinit();
    var middle = try createMergeReader(std.testing.allocator, &middle_log, &middle_entries);
    defer middle.deinit();
    var oldest = try createMergeReader(std.testing.allocator, &oldest_log, &oldest_entries);
    defer oldest.deinit();
    const inputs = [_]*MergeReader{ &newest, &middle, &oldest };
    const strategies = [_]MergeMerger.EntryCountStrategy{
        .upper_bound,
        .exact_two_pass,
        .{ .estimate = 1 },
    };

    for (strategies) |strategy| {
        var output_log = try MergeLog.init(std.testing.allocator);
        defer output_log.deinit();
        try MergeMerger.run(
            std.testing.allocator,
            &inputs,
            &output_log,
            .{
                .comparator_id = 42,
                .settings = merge_output_settings,
                .entry_count_strategy = strategy,
            },
            {},
        );
        var output = try MergeReader.init(
            std.testing.allocator,
            &output_log,
            .{
                .comparator_id = 42,
                .index_backend = .memory,
            },
            {},
        );
        defer output.deinit();
        var data_page: [merge_output_settings.data_page_bytes]u8 = undefined;
        var key: [merge_output_settings.max_key_bytes]u8 = undefined;
        var scratch = MergeReader.ReadScratchType{
            .data_page = &data_page,
            .key = &key,
        };

        try expectMergeEntry(&output, &scratch, "ant", "highest-lsn", .value, 7);
        try expectMergeEntry(&output, &scratch, "bat", "b", .value, 4);
        try expectMergeEntry(&output, &scratch, "cat", "", .tombstone, 11);
        try expectMergeEntry(&output, &scratch, "dog", "newest-tie", .value, 9);
        try expectMergeEntry(&output, &scratch, "eel", "e", .value, 3);
        try expectMergeEntry(&output, &scratch, "fox", "f", .value, 2);
        try std.testing.expectEqual(@as(u64, 6), output.footer.entry_count);
        try std.testing.expectEqual(@as(u16, 2), output.footer.min_lsn);
        try std.testing.expectEqual(@as(u16, 11), output.footer.max_lsn);
        try std.testing.expectEqual(
            merge_output_settings.index_page_bytes,
            output.footer.settings.index_page_bytes,
        );
    }
}

test "SSTable merger can drop winning tombstones" {
    const newest_entries = [_]MergeInput{
        .{ .key = "ant", .value = "", .flags = .tombstone, .lsn = 2 },
        .{ .key = "cat", .value = "c", .flags = .value, .lsn = 3 },
    };
    const oldest_entries = [_]MergeInput{
        .{ .key = "ant", .value = "old", .flags = .value, .lsn = 1 },
        .{ .key = "bee", .value = "b", .flags = .value, .lsn = 1 },
    };

    var newest_log = try MergeLog.init(std.testing.allocator);
    defer newest_log.deinit();
    var oldest_log = try MergeLog.init(std.testing.allocator);
    defer oldest_log.deinit();
    var newest = try createMergeReader(std.testing.allocator, &newest_log, &newest_entries);
    defer newest.deinit();
    var oldest = try createMergeReader(std.testing.allocator, &oldest_log, &oldest_entries);
    defer oldest.deinit();
    const inputs = [_]*MergeReader{ &newest, &oldest };
    var output_log = try MergeLog.init(std.testing.allocator);
    defer output_log.deinit();
    try MergeMerger.run(
        std.testing.allocator,
        &inputs,
        &output_log,
        .{
            .comparator_id = 42,
            .settings = merge_output_settings,
            .entry_count_strategy = .exact_two_pass,
            .drop_winning_tombstones = true,
        },
        {},
    );
    var output = try MergeReader.init(
        std.testing.allocator,
        &output_log,
        .{
            .comparator_id = 42,
            .index_backend = .memory,
        },
        {},
    );
    defer output.deinit();
    var data_page: [merge_output_settings.data_page_bytes]u8 = undefined;
    var key: [merge_output_settings.max_key_bytes]u8 = undefined;
    var scratch = MergeReader.ReadScratchType{
        .data_page = &data_page,
        .key = &key,
    };

    try std.testing.expect((try output.find("ant", &scratch)) == null);
    try expectMergeEntry(&output, &scratch, "bee", "b", .value, 1);
    try expectMergeEntry(&output, &scratch, "cat", "c", .value, 3);
    try std.testing.expectEqual(@as(u64, 2), output.footer.entry_count);
}

test "SSTable merger leaves no output when cleanup drops every entry" {
    const entries = [_]MergeInput{
        .{ .key = "ant", .value = "", .flags = .tombstone, .lsn = 1 },
    };
    var input_log = try MergeLog.init(std.testing.allocator);
    defer input_log.deinit();
    var input = try createMergeReader(std.testing.allocator, &input_log, &entries);
    defer input.deinit();
    const inputs = [_]*MergeReader{&input};
    var output_log = try MergeLog.init(std.testing.allocator);
    defer output_log.deinit();

    try std.testing.expectError(
        error.EmptyOutput,
        MergeMerger.run(
            std.testing.allocator,
            &inputs,
            &output_log,
            .{
                .comparator_id = 42,
                .settings = merge_output_settings,
                .drop_winning_tombstones = true,
            },
            {},
        ),
    );
    try std.testing.expectEqual(@as(u64, 0), output_log.size());
}

test "SSTable merger rejects insufficient output limits before writing" {
    const entries = [_]MergeInput{
        .{ .key = "ant", .value = "value", .flags = .value, .lsn = 1 },
    };
    var input_log = try MergeLog.init(std.testing.allocator);
    defer input_log.deinit();
    var input = try createMergeReader(std.testing.allocator, &input_log, &entries);
    defer input.deinit();
    const inputs = [_]*MergeReader{&input};
    var output_log = try MergeLog.init(std.testing.allocator);
    defer output_log.deinit();
    var output_settings = merge_output_settings;
    output_settings.max_value_bytes = merge_source_settings.max_value_bytes - 1;

    try std.testing.expectError(
        error.OutputValueTooSmall,
        MergeMerger.run(
            std.testing.allocator,
            &inputs,
            &output_log,
            .{
                .comparator_id = 42,
                .settings = output_settings,
            },
            {},
        ),
    );
    try std.testing.expectEqual(@as(u64, 0), output_log.size());
}

test "SSTable data page selects a coded block by fence key" {
    const Format = sstable.SstableFormat(u64, u32, u32, .little);
    const DataPage = sstable.DataPage(Format);
    var bytes: [512]u8 = undefined;
    var page = try DataPage.View(false).init(&bytes);
    try page.format();
    try page.append("cat", "block-a");
    try page.append("dog", "block-b");
    try page.append("fox", "block-c");

    try std.testing.expectEqual(@as(usize, 3), page.blockCount());
    try std.testing.expectEqualSlices(u8, "dog", try page.fenceKey(1));
    try std.testing.expectEqualSlices(u8, "block-c", try page.codedBlock(2));
    try std.testing.expectEqual(@as(usize, 0), try page.lowerBound("ant", compareBytes, {}));
    try std.testing.expectEqual(@as(usize, 1), try page.lowerBound("cow", compareBytes, {}));
    try std.testing.expectEqual(@as(usize, 3), try page.lowerBound("zebra", compareBytes, {}));

    const reopened = try DataPage.View(true).init(&bytes);
    try reopened.validate();
}

test "SSTable writer appends a validated footer to FileLog" {
    const Format = sstable.SstableFormat(u64, u32, u32, .little);
    const FileLog = @import("fullaz").device.FileLog(u64);
    const Writer = sstable.Writer(Format, FileLog, compareBytes, void);
    const Footer = sstable.Footer(Format);
    const path = "test-sstable-writer.log";

    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var log = try FileLog.create(std.testing.io, path);
    defer log.deinit();
    var writer = try Writer.init(
        std.testing.allocator,
        &log,
        .{
            .entry_count = 3,
            .comparator_id = 42,
            .settings = .{
                .max_entries_per_coded_block = 2,
                .max_coded_block_bytes = 128,
                .data_page_bytes = 512,
                .index_page_bytes = 512,
                .max_key_bytes = 32,
                .max_value_bytes = 32,
            },
        },
        {},
    );
    defer writer.deinit();

    try writer.add("ant", "1");
    try std.testing.expectError(error.DuplicateKey, writer.add("ant", "again"));
    try std.testing.expectError(error.UnorderedKey, writer.add("aardvark", "0"));
    try writer.add("bee", "2");
    try writer.add("cat", "3");
    try writer.finish();

    var footer_bytes: [512]u8 = undefined;
    const footer_offset = log.size() - @sizeOf(Footer.Trailer) - footer_bytes.len;
    try log.readAt(footer_offset, &footer_bytes);
    const footer = try Footer.View(true).init(&footer_bytes);
    const info = try footer.validate(footer_offset);

    try std.testing.expectEqual(@as(u32, 42), info.comparator_id);
    try std.testing.expectEqual(@as(u64, 3), info.entry_count);
    try std.testing.expectEqual(@as(u32, 1), info.data_page_count);
    try std.testing.expect(info.data_length < info.settings.data_page_bytes);
    try std.testing.expect(info.index_page_count > 0);
    try std.testing.expect(info.index_root_page_id < info.index_page_count);
    comptime sstable.interfaces.assertWriter(Writer);
}

test "SSTable writer permits an estimated entry count" {
    const Format = sstable.SstableFormat(u64, u32, u32, .little);
    const MemoryLog = @import("fullaz").device.MemoryLog(u64);
    const Writer = sstable.Writer(Format, MemoryLog, compareBytes, void);
    const Footer = sstable.Footer(Format);

    var log = try MemoryLog.init(std.testing.allocator);
    defer log.deinit();
    var writer = try Writer.init(
        std.testing.allocator,
        &log,
        .{
            .entry_count = 1,
            .enforce_entry_count = false,
            .comparator_id = 42,
            .settings = .{
                .max_entries_per_coded_block = 2,
                .max_coded_block_bytes = 128,
                .data_page_bytes = 512,
                .index_page_bytes = 512,
                .max_key_bytes = 32,
                .max_value_bytes = 32,
            },
        },
        {},
    );
    defer writer.deinit();
    try writer.add("ant", "1");
    try writer.add("bee", "2");
    try writer.finish();

    var footer_bytes: [512]u8 = undefined;
    const footer_offset = log.size() - @sizeOf(Footer.Trailer) - footer_bytes.len;
    try log.readAt(footer_offset, &footer_bytes);
    const footer = try Footer.View(true).init(&footer_bytes);
    const info = try footer.validate(footer_offset);
    try std.testing.expectEqual(@as(u64, 2), info.entry_count);
}

test "SSTable merger rejects empty inputs" {
    const Format = sstable.SstableFormat(u64, u32, u32, .little);
    const MemoryLog = @import("fullaz").device.MemoryLog(u64);
    const Merger = sstable.Merger(Format, MemoryLog, compareBytes, void);

    var output_log = try MemoryLog.init(std.testing.allocator);
    defer output_log.deinit();
    try std.testing.expectError(
        error.NoInputs,
        Merger.run(
            std.testing.allocator,
            &.{},
            &output_log,
            .{ .comparator_id = 42 },
            {},
        ),
    );
}

test "SSTable reader preserves entry metadata with both index backends" {
    const Format = sstable.SstableFormatWithLsn(u64, u32, u32, u16, .little);
    const FileLog = @import("fullaz").device.FileLog(u64);
    const Writer = sstable.Writer(Format, FileLog, compareBytes, void);
    const Reader = sstable.Reader(Format, FileLog, compareBytes, void);
    const path = "test-sstable-reader.log";

    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var log = try FileLog.create(std.testing.io, path);
    defer log.deinit();
    var writer = try Writer.init(
        std.testing.allocator,
        &log,
        .{
            .entry_count = 5,
            .comparator_id = 7,
            .settings = .{
                .max_entries_per_coded_block = 2,
                .max_coded_block_bytes = 128,
                .data_page_bytes = 512,
                .index_page_bytes = 512,
                .max_key_bytes = 32,
                .max_value_bytes = 32,
            },
        },
        {},
    );
    defer writer.deinit();
    try writer.addWithMetadata("ant", "1", .{ .flags = .value, .lsn = 7 });
    try writer.add("bee", "2");
    try writer.addTombstone("cat", 8);
    try writer.add("dog", "4");
    try writer.add("eel", "5");
    try writer.finish();

    inline for ([_]sstable.IndexBackend{ .memory, .file }) |backend| {
        var reader = try Reader.init(
            std.testing.allocator,
            &log,
            .{
                .comparator_id = 7,
                .index_backend = backend,
            },
            {},
        );
        defer reader.deinit();
        var data_page: [512]u8 = undefined;
        var key: [32]u8 = undefined;
        var scratch = Reader.ReadScratchType{
            .data_page = &data_page,
            .key = &key,
        };
        const ant = (try reader.find("ant", &scratch)).?;
        try std.testing.expectEqualSlices(u8, "1", ant.value);
        try std.testing.expectEqual(.value, ant.metadata.flags);
        try std.testing.expectEqual(@as(u16, 7), ant.metadata.lsn);
        const cat = (try reader.find("cat", &scratch)).?;
        try std.testing.expectEqualSlices(u8, "", cat.value);
        try std.testing.expectEqual(.tombstone, cat.metadata.flags);
        try std.testing.expectEqual(@as(u16, 8), cat.metadata.lsn);
        try std.testing.expectEqualSlices(u8, "5", (try reader.find("eel", &scratch)).?.value);
        try std.testing.expectEqual(@as(u16, 0), reader.footer.min_lsn);
        try std.testing.expectEqual(@as(u16, 8), reader.footer.max_lsn);
        try std.testing.expect((try reader.find("aardvark", &scratch)) == null);
        try std.testing.expect((try reader.find("cow", &scratch)) == null);
        try std.testing.expect((try reader.find("zebra", &scratch)) == null);
        // A key that was never added and is rejected by this table's Bloom filter.
        try std.testing.expect((try reader.find("definitely-not-present", &scratch)) == null);

        var iterator = try reader.iterator(&scratch);
        const expected = [_]struct {
            key: []const u8,
            value: []const u8,
            flags: sstable.EntryFlags,
            lsn: u16,
        }{
            .{ .key = "ant", .value = "1", .flags = .value, .lsn = 7 },
            .{ .key = "bee", .value = "2", .flags = .value, .lsn = 0 },
            .{ .key = "cat", .value = "", .flags = .tombstone, .lsn = 8 },
            .{ .key = "dog", .value = "4", .flags = .value, .lsn = 0 },
            .{ .key = "eel", .value = "5", .flags = .value, .lsn = 0 },
        };
        for (expected) |expected_entry| {
            const scanned = (try iterator.next()).?;
            try std.testing.expectEqualSlices(u8, expected_entry.key, scanned.key);
            try std.testing.expectEqualSlices(u8, expected_entry.value, scanned.value);
            try std.testing.expectEqual(expected_entry.flags, scanned.metadata.flags);
            try std.testing.expectEqual(expected_entry.lsn, scanned.metadata.lsn);
        }
        try std.testing.expect((try iterator.next()) == null);
    }
    comptime sstable.interfaces.assertReader(Reader);
}
