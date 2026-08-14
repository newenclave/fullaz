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
        try std.testing.expect((try reader.find("aardvark", &scratch)) == null);
        try std.testing.expect((try reader.find("cow", &scratch)) == null);
        try std.testing.expect((try reader.find("zebra", &scratch)) == null);
        // A key that was never added and is rejected by this table's Bloom filter.
        try std.testing.expect((try reader.find("definitely-not-present", &scratch)) == null);
    }
    comptime sstable.interfaces.assertReader(Reader);
}
