const std = @import("std");
const fullaz = @import("fullaz");

const StringPrefixBlock = fullaz.keys.prefix_block.StringPrefixBlock;

test "Keys: build prefix" {
    const allocator = std.testing.allocator;

    const PrefixInfo = StringPrefixBlock.PrefixInfo;
    const Builder = StringPrefixBlock.Builder;

    const template = "compressor";

    var buf: [10]PrefixInfo = .{PrefixInfo{ .common = 0, .suffix = "" }} ** 10;
    var builder = Builder.impl(allocator, template, buf[0..]);
    defer builder.deinit();

    try builder.add("compound");
    try builder.add("component");

    const current = builder.current();

    try std.testing.expect(current.len == 2);
    try std.testing.expect(current[0].common == 4);
    try std.testing.expect(std.mem.eql(u8, current[0].suffix, "ound"));
    try std.testing.expect(current[1].common == 5);
    try std.testing.expect(std.mem.eql(u8, current[1].suffix, "nent"));
}

test "Keys: build prefix without common part" {
    const allocator = std.testing.allocator;
    const PrefixInfo = StringPrefixBlock.PrefixInfo;
    const Builder = StringPrefixBlock.Builder;

    const template = "compressor";

    var buf: [10]PrefixInfo =
        .{PrefixInfo{ .common = 0, .suffix = "" }} ** 10;

    var builder = Builder.impl(allocator, template, buf[0..]);
    defer builder.deinit();

    try builder.add("banana");

    const current = builder.current();

    try std.testing.expectEqual(@as(usize, 1), current.len);
    try std.testing.expectEqual(@as(usize, 0), current[0].common);
    try std.testing.expectEqualStrings("banana", current[0].suffix);
}

test "Keys: build prefix for equal keys" {
    const allocator = std.testing.allocator;

    const PrefixInfo = StringPrefixBlock.PrefixInfo;
    const Builder = StringPrefixBlock.Builder;

    const template = "compressor";

    var buf: [10]PrefixInfo =
        .{PrefixInfo{ .common = 0, .suffix = "" }} ** 10;

    var builder = Builder.impl(allocator, template, buf[0..]);
    defer builder.deinit();

    try builder.add("compressor");

    const current = builder.current();

    try std.testing.expectEqual(@as(usize, 1), current.len);
    try std.testing.expectEqual(template.len, current[0].common);
    try std.testing.expectEqualStrings("", current[0].suffix);
}

test "Keys: build prefix when next key is shorter" {
    const allocator = std.testing.allocator;

    const PrefixInfo = StringPrefixBlock.PrefixInfo;
    const Builder = StringPrefixBlock.Builder;

    const template = "compression";

    var buf: [10]PrefixInfo =
        .{PrefixInfo{ .common = 0, .suffix = "" }} ** 10;

    var builder = Builder.impl(allocator, template, buf[0..]);
    defer builder.deinit();

    try builder.add("compress");

    const current = builder.current();

    try std.testing.expectEqual(@as(usize, 1), current.len);
    try std.testing.expectEqual(@as(usize, 8), current[0].common);
    try std.testing.expectEqualStrings("", current[0].suffix);
}

test "Keys: build prefix when previous key is prefix" {
    const allocator = std.testing.allocator;
    const PrefixInfo = StringPrefixBlock.PrefixInfo;
    const Builder = StringPrefixBlock.Builder;

    const template = "comp";

    var buf: [10]PrefixInfo =
        .{PrefixInfo{ .common = 0, .suffix = "" }} ** 10;

    var builder = Builder.impl(allocator, template, buf[0..]);
    defer builder.deinit();

    try builder.add("component");

    const current = builder.current();

    try std.testing.expectEqual(@as(usize, 1), current.len);
    try std.testing.expectEqual(@as(usize, 4), current[0].common);
    try std.testing.expectEqualStrings("onent", current[0].suffix);
}

test "Keys: build chained prefixes" {
    const allocator = std.testing.allocator;
    const PrefixInfo = StringPrefixBlock.PrefixInfo;
    const Builder = StringPrefixBlock.Builder;

    const template = "file";

    var buf: [10]PrefixInfo =
        .{PrefixInfo{ .common = 0, .suffix = "" }} ** 10;

    var builder = Builder.impl(allocator, template, buf[0..]);
    defer builder.deinit();

    try builder.add("filesystem");
    try builder.add("filesystem_cache");
    try builder.add("filesystem_cache_entry");
    try builder.add("filesystem_cache_entry_count");

    const current = builder.current();

    try std.testing.expectEqual(@as(usize, 4), current.len);

    try std.testing.expectEqual(@as(usize, 4), current[0].common);
    try std.testing.expectEqualStrings("system", current[0].suffix);

    try std.testing.expectEqual(
        "filesystem".len,
        current[1].common,
    );
    try std.testing.expectEqualStrings("_cache", current[1].suffix);

    try std.testing.expectEqual(
        "filesystem_cache".len,
        current[2].common,
    );
    try std.testing.expectEqualStrings("_entry", current[2].suffix);

    try std.testing.expectEqual(
        "filesystem_cache_entry".len,
        current[3].common,
    );
    try std.testing.expectEqualStrings("_count", current[3].suffix);
}

test "Keys: build empty key" {
    const PrefixInfo = StringPrefixBlock.PrefixInfo;
    const Builder = StringPrefixBlock.Builder;

    const allocator = std.testing.allocator;
    const template = "compressor";

    var buf: [10]PrefixInfo =
        .{PrefixInfo{ .common = 0, .suffix = "" }} ** 10;

    var builder = Builder.impl(allocator, template, buf[0..]);
    defer builder.deinit();

    try builder.add("");

    const current = builder.current();

    try std.testing.expectEqual(@as(usize, 1), current.len);
    try std.testing.expectEqual(@as(usize, 0), current[0].common);
    try std.testing.expectEqualStrings("", current[0].suffix);
}

test "Keys: build from empty template" {
    const allocator = std.testing.allocator;
    const PrefixInfo = StringPrefixBlock.PrefixInfo;
    const Builder = StringPrefixBlock.Builder;

    var buf: [10]PrefixInfo =
        .{PrefixInfo{ .common = 0, .suffix = "" }} ** 10;

    var builder = Builder.impl(allocator, "", buf[0..]);
    defer builder.deinit();

    try builder.add("component");
    try builder.add("compound");

    const current = builder.current();

    try std.testing.expectEqual(@as(usize, 2), current.len);

    try std.testing.expectEqual(@as(usize, 0), current[0].common);
    try std.testing.expectEqualStrings("component", current[0].suffix);

    try std.testing.expectEqual(@as(usize, 5), current[1].common);
    try std.testing.expectEqualStrings("und", current[1].suffix);
}

test "Keys: builder reports insufficient output buffer" {
    const allocator = std.testing.allocator;
    const PrefixInfo = StringPrefixBlock.PrefixInfo;
    const Builder = StringPrefixBlock.Builder;

    var buf: [1]PrefixInfo =
        .{PrefixInfo{ .common = 0, .suffix = "" }} ** 1;

    var builder = Builder.impl(allocator, "compressor", buf[0..]);
    defer builder.deinit();

    try builder.add("compound");

    try std.testing.expectError(
        error.BufferTooSmall,
        builder.add("component"),
    );
}

test "Keys: build and get chained prefixes" {
    const allocator = std.testing.allocator;
    const PrefixInfo = StringPrefixBlock.PrefixInfo;
    const Builder = StringPrefixBlock.Builder;
    const Reader = StringPrefixBlock.Reader;
    _ = Reader;

    const template = "file";

    var buf: [10]PrefixInfo =
        .{PrefixInfo{ .common = 0, .suffix = "" }} ** 10;

    var builder = Builder.impl(allocator, template, buf[0..]);
    defer builder.deinit();

    try builder.add("filesystem");
    try builder.add("filesystem_cache");
    try builder.add("filesystem_cache_entry");
    try builder.add("filesystem_cache_entry_count");

    const current = builder.current();

    try std.testing.expectEqual(@as(usize, 4), current.len);
    // const reader = Reader.impl(allocator, current, template);
    // defer reader.deinit();

    var reader = builder.reader();
    defer reader.deinit();

    for (0..4) |i| {
        var out: [256]u8 = undefined;
        const key = try reader.get(i, out[0..]);
        std.debug.print("key[{}]: {s}\n", .{ i, key });
        try std.testing.expectEqualStrings(
            switch (i) {
                0 => "file",
                1 => "filesystem",
                2 => "filesystem_cache",
                3 => "filesystem_cache_entry",
                4 => "filesystem_cache_entry_count",
                else => unreachable,
            },
            key,
        );
    }

    var itr = try reader.iterator();
    defer itr.deinit();
    while (true) {
        const out = itr.current();
        std.debug.print("itr key: {s}\n", .{out});
        if (try itr.advance() == false) {
            break;
        }
    }
}
