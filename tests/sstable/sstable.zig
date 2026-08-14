const std = @import("std");
const sstable = @import("fullaz").sstable;

test "SSTable format records wire types" {
    const Format = sstable.SstableFormat(u64, u32, u32, .little);

    try std.testing.expect(Format.Offset == u64);
    try std.testing.expect(Format.PageId == u32);
    try std.testing.expect(Format.DataIndex == u32);
    try std.testing.expect(Format.Endian == .little);
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

        pub fn find(_: *@This(), _: []const u8, _: *ReadScratchType) Error!?[]const u8 {
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
