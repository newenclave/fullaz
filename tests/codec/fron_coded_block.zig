const std = @import("std");
const fullaz = @import("fullaz");
const algo = fullaz.core.algorithm;

const StrCmp = struct {
    pub fn cmp(_: void, a: u8, b: u8) algo.Order {
        if (a < b) {
            return .lt;
        } else if (b < a) {
            return .gt;
        } else {
            return .eq;
        }
    }
};

const StrSliceCmp = struct {
    pub fn cmp(_: void, a: []const u8, b: []const u8) algo.Order {
        const n = @min(a.len, b.len);
        for (0..n) |i| {
            const res = StrCmp.cmp({}, a[i], b[i]);
            if (res != .eq) {
                return res;
            }
        }

        if (a.len < b.len) {
            return .lt;
        }
        if (a.len > b.len) {
            return .gt;
        }
        return .eq;
    }
};

const UnorderedSliceCmp = struct {
    pub fn cmp(_: void, _: []const u8, _: []const u8) algo.PartialOrder {
        return .unordered;
    }
};

const codec = fullaz.codec;
const BlockWriter = codec.bounded_buffer.MemoryBlockWriter(u8);
const BlockReader = codec.bounded_buffer.MemoryBlockView(u8);

const FrontCodedBlock = codec.front_coded_block.FrontCodedBlock(
    u8,
    u16,
    u32,
    BlockWriter,
    BlockReader,
    .little,
    true,
    StrCmp.cmp,
    void,
);

const MetadataFrontCodedBlock = codec.front_coded_block.FrontCodedBlockWithMetadata(
    u8,
    u16,
    u32,
    BlockWriter,
    BlockReader,
    .little,
    true,
    StrCmp.cmp,
    void,
    2,
);

const ZeroMetadataFrontCodedBlock = codec.front_coded_block.FrontCodedBlockWithMetadata(
    u8,
    u16,
    u32,
    BlockWriter,
    BlockReader,
    .little,
    true,
    StrCmp.cmp,
    void,
    0,
);

const SmallIndexFrontCodedBlock = codec.front_coded_block.FrontCodedBlock(
    u8,
    u8,
    u32,
    BlockWriter,
    BlockReader,
    std.builtin.Endian.little,
    true,
    StrCmp.cmp,
    void,
);

const SmallBlockSizeFrontCodedBlock = codec.front_coded_block.FrontCodedBlock(
    u8,
    u16,
    u8,
    BlockWriter,
    BlockReader,
    std.builtin.Endian.little,
    true,
    StrCmp.cmp,
    void,
);

var counting_view_deinit_count: usize = 0;

const CountingBlockView = struct {
    const Self = @This();
    pub const Error = error{};

    items: []const u8,

    pub fn init(items: []const u8) Self {
        return .{ .items = items };
    }

    pub fn deinit(_: *Self) void {
        counting_view_deinit_count += 1;
    }

    pub fn at(self: *const Self, index: usize, length: usize) Error![]const u8 {
        return self.items[index .. index + length];
    }

    pub fn slice(self: *const Self) []const u8 {
        return self.items;
    }

    pub fn len(self: *const Self) Error!usize {
        return self.items.len;
    }
};

const CountingViewFrontCodedBlock = codec.front_coded_block.FrontCodedBlock(
    u8,
    u16,
    u32,
    BlockWriter,
    CountingBlockView,
    std.builtin.Endian.little,
    true,
    StrCmp.cmp,
    void,
);

const NoBufFieldWriter = struct {
    const Self = @This();
    pub const Error = fullaz.core.errors.SpaceError;

    storage: []u8,
    len: usize = 0,

    pub fn init(storage: []u8) Self {
        return .{ .storage = storage };
    }

    pub fn deinit(_: *Self) void {}

    pub fn append(self: *Self, items: []const u8) Error!void {
        if (items.len > self.remaining()) {
            return Error.BufferTooSmall;
        }

        @memcpy(self.storage[self.len..][0..items.len], items);
        self.len += items.len;
    }

    pub fn extend(self: *Self, len: usize) Error!void {
        if (len > self.remaining()) {
            return Error.BufferTooSmall;
        }
        self.len += len;
    }

    pub fn used(self: *const Self) []const u8 {
        return self.storage[0..self.len];
    }

    pub fn at(self: *const Self, index: usize, len: usize) []const u8 {
        return self.storage[index .. index + len];
    }

    pub fn atMut(self: *const Self, index: usize, len: usize) []u8 {
        return self.storage[index .. index + len];
    }

    pub fn remaining(self: *const Self) usize {
        return self.storage.len - self.len;
    }

    pub fn reset(self: *Self) void {
        self.len = 0;
    }

    pub fn view(self: *const Self) BlockReader {
        return .init(self.used());
    }
};

const NoBufWriterFrontCodedBlock = codec.front_coded_block.FrontCodedBlock(
    u8,
    u16,
    u32,
    NoBufFieldWriter,
    BlockReader,
    std.builtin.Endian.little,
    true,
    StrCmp.cmp,
    void,
);

const FailingWriter = struct {
    const Self = @This();
    pub const Error = error{WriteFailed};

    storage: []u8,

    pub fn init(storage: []u8) Self {
        return .{ .storage = storage };
    }

    pub fn extend(_: *Self, _: usize) Error!void {
        return Error.WriteFailed;
    }

    pub fn used(_: *const Self) []const u8 {
        return "";
    }

    pub fn at(self: *const Self, index: usize, len: usize) []const u8 {
        return self.storage[index .. index + len];
    }

    pub fn atMut(self: *const Self, index: usize, len: usize) []u8 {
        return self.storage[index .. index + len];
    }

    pub fn remaining(self: *const Self) usize {
        return self.storage.len;
    }
};

const FailingWriterFrontCodedBlock = codec.front_coded_block.FrontCodedBlock(
    u8,
    u16,
    u32,
    FailingWriter,
    BlockReader,
    std.builtin.Endian.little,
    true,
    StrCmp.cmp,
    void,
);

const FailingView = struct {
    const Self = @This();
    pub const Error = error{ReadFailed};

    items: []const u8,

    pub fn init(items: []const u8) Self {
        return .{ .items = items };
    }

    pub fn deinit(_: *Self) void {}

    pub fn at(self: *const Self, index: usize, length: usize) Error![]const u8 {
        return self.items[index .. index + length];
    }

    pub fn len(_: *const Self) Error!usize {
        return Error.ReadFailed;
    }
};

const FailingViewFrontCodedBlock = codec.front_coded_block.FrontCodedBlock(
    u8,
    u16,
    u32,
    BlockWriter,
    FailingView,
    std.builtin.Endian.little,
    true,
    StrCmp.cmp,
    void,
);

const HEADER_SIZE = @sizeOf(FrontCodedBlock.Header);
const ENTRY_HEADER_SIZE = @sizeOf(FrontCodedBlock.EntryHeader);

const TestEntry = struct {
    key: []const u8,
    value: []const u8,
};

const sample_entries = [_]TestEntry{
    .{ .key = "filesystem", .value = "v0" },
    .{ .key = "filesystem_cache", .value = "v1" },
    .{ .key = "filesystem_cache_entry", .value = "v2" },
    .{ .key = "filesystem_cache_entry_low", .value = "v3" },
};

fn expectedUsedBytes(entries: []const TestEntry) usize {
    var used: usize = HEADER_SIZE;
    var prev: []const u8 = "";
    for (entries) |entry| {
        const shared = algo.commonPrefixLength(u8, prev, entry.key, StrCmp.cmp, {}) catch unreachable;
        used += ENTRY_HEADER_SIZE + (entry.key.len - shared) + entry.value.len;
        prev = entry.key;
    }
    return used;
}

fn maxKeyLen(entries: []const TestEntry) usize {
    var max: usize = 0;
    for (entries) |entry| {
        max = @max(max, entry.key.len);
    }
    return max;
}

fn entryHeaderAt(buf: []u8, offset: usize) *FrontCodedBlock.EntryHeader {
    return @ptrCast(buf[offset .. offset + ENTRY_HEADER_SIZE].ptr);
}

fn blockHeaderAt(buf: []u8) *FrontCodedBlock.Header {
    return @ptrCast(buf[0..HEADER_SIZE].ptr);
}

test "Codec: bounded buffer contracts match front-coded block usage" {
    comptime {
        codec.bounded_buffer.assertMemoryBlockWriter(BlockWriter);
        codec.bounded_buffer.assertMemoryBlockWriter(NoBufFieldWriter);
        codec.bounded_buffer.assertMemoryBlockWriter(FailingWriter);
        codec.bounded_buffer.assertMemoryBlockView(BlockReader);
        codec.bounded_buffer.assertMemoryBlockView(CountingBlockView);
        codec.bounded_buffer.assertMemoryBlockView(FailingView);
    }
}

test "Codec: FrontCodedBlock builder includes writer errors" {
    var buf = [_]u8{0} ** 128;
    var scratch: [32]u8 = undefined;

    try std.testing.expectError(
        error.WriteFailed,
        FailingWriterFrontCodedBlock.Builder.init(FailingWriter.init(buf[0..]), scratch[0..]),
    );
}

test "Codec: FrontCodedBlock reader includes view errors" {
    var buf = [_]u8{0} ** 128;

    try std.testing.expectError(
        error.ReadFailed,
        FailingViewFrontCodedBlock.Reader.init(FailingView.init(buf[0..])),
    );
}

test "Codec: FrontCodedBlock writes header metadata" {
    var buf = [_]u8{0} ** 1024;
    var scratch: [256]u8 = undefined;
    var builder = try FrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), scratch[0..]);
    defer builder.deinit();

    try std.testing.expectEqual(@as(usize, HEADER_SIZE), builder.block_writer.used().len);

    for (sample_entries) |entry| {
        try std.testing.expect(builder.canAdd(entry.key, entry.value));
        try builder.add(entry.key, entry.value);
    }

    var reader = try builder.reader();
    defer reader.deinit();

    try std.testing.expectEqual(sample_entries.len, try reader.entryCount());
    try std.testing.expectEqual(expectedUsedBytes(sample_entries[0..]), try reader.usedBytes());
    try std.testing.expectEqual(maxKeyLen(sample_entries[0..]), try reader.maxKeyLen());
    try std.testing.expectEqual(try reader.usedBytes(), builder.block_writer.used().len);
}

test "Codec: FrontCodedBlock supports empty block" {
    var buf = [_]u8{0} ** 128;
    var scratch: [32]u8 = undefined;
    var builder = try FrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), scratch[0..]);
    defer builder.deinit();

    var reader = try builder.reader();
    defer reader.deinit();

    try std.testing.expectEqual(@as(usize, 0), try reader.entryCount());
    try std.testing.expectEqual(@as(usize, HEADER_SIZE), try reader.usedBytes());
    try std.testing.expectEqual(@as(usize, 0), try reader.maxKeyLen());

    var read_scratch: [32]u8 = undefined;
    var itr = try reader.iterator(read_scratch[0..]);
    defer itr.deinit();

    try std.testing.expect(itr.done());
}

test "Codec: FrontCodedBlock iterator rebuilds keys with caller scratch" {
    var buf = [_]u8{0} ** 1024;
    var builder_scratch: [256]u8 = undefined;
    var builder = try FrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), builder_scratch[0..]);
    defer builder.deinit();

    for (sample_entries) |entry| {
        try builder.add(entry.key, entry.value);
    }

    var reader = try builder.reader();
    defer reader.deinit();

    var read_scratch: [256]u8 = undefined;
    var itr = try reader.iterator(read_scratch[0..]);
    defer itr.deinit();

    var index: usize = 0;
    while (!itr.done()) : (index += 1) {
        try std.testing.expect(index < sample_entries.len);
        try std.testing.expectEqualStrings(sample_entries[index].key, itr.scratchKey());
        try std.testing.expectEqualStrings(sample_entries[index].value, try itr.value());
        try itr.next();
    }

    try std.testing.expectEqual(sample_entries.len, index);
}

test "Codec: FrontCodedBlock preserves per-entry metadata" {
    var buf = [_]u8{0} ** 256;
    var builder_scratch: [32]u8 = undefined;
    var builder = try MetadataFrontCodedBlock.Builder.init(
        BlockWriter.init(buf[0..]),
        builder_scratch[0..],
    );
    defer builder.deinit();

    try builder.addWithMetadata("ant", "1", &[_]u8{ 0xa5, 0x01 });
    try builder.add("bee", "2");

    var reader = try builder.reader();
    defer reader.deinit();

    var read_scratch: [32]u8 = undefined;
    var itr = try reader.iterator(read_scratch[0..]);
    defer itr.deinit();

    try std.testing.expectEqualSlices(u8, "ant", itr.scratchKey());
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xa5, 0x01 }, try itr.metadata());
    try itr.next();
    try std.testing.expectEqualSlices(u8, "bee", itr.scratchKey());
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0 }, try itr.metadata());

    var found_scratch: [32]u8 = undefined;
    var found = (try reader.find("ant", found_scratch[0..], StrSliceCmp.cmp, {})).?;
    defer found.deinit();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xa5, 0x01 }, try found.metadata());
}

test "Codec: FrontCodedBlock validates metadata length" {
    var buf = [_]u8{0} ** 128;
    var scratch: [32]u8 = undefined;
    var builder = try MetadataFrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), scratch[0..]);
    defer builder.deinit();

    try std.testing.expect(!builder.canAddWithMetadata("ant", "1", "x"));
    try std.testing.expectError(error.InvalidMetadata, builder.addWithMetadata("ant", "1", "x"));
}

test "Codec: FrontCodedBlock accounts for metadata capacity" {
    const block_size = @sizeOf(MetadataFrontCodedBlock.Header) +
        @sizeOf(MetadataFrontCodedBlock.EntryHeader) +
        "ant".len +
        "1".len +
        2;
    var buf: [block_size]u8 = undefined;
    var scratch: [32]u8 = undefined;
    var builder = try MetadataFrontCodedBlock.Builder.init(BlockWriter.init(&buf), scratch[0..]);
    defer builder.deinit();

    try std.testing.expect(builder.canAddWithMetadata("ant", "1", &[_]u8{ 0, 0 }));
    try builder.addWithMetadata("ant", "1", &[_]u8{ 0, 0 });
    try std.testing.expectEqual(block_size, builder.usedBytes().len);
}

test "Codec: FrontCodedBlock rejects truncated metadata" {
    var buf = [_]u8{0} ** 128;
    var scratch: [32]u8 = undefined;
    var builder = try MetadataFrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), scratch[0..]);
    defer builder.deinit();

    try builder.addWithMetadata("ant", "1", &[_]u8{ 0, 0 });
    const header: *MetadataFrontCodedBlock.Header = @ptrCast(buf[0..].ptr);
    header.used_bytes.set(@intCast(builder.usedBytes().len - 1));

    try std.testing.expectError(
        error.BufferTooSmall,
        MetadataFrontCodedBlock.Reader.init(BlockReader.init(builder.usedBytes())),
    );
}

test "Codec: FrontCodedBlock metadata length zero preserves the wire format" {
    var default_buf = [_]u8{0} ** 256;
    var metadata_buf = [_]u8{0} ** 256;
    var default_scratch: [32]u8 = undefined;
    var metadata_scratch: [32]u8 = undefined;
    var default_builder = try FrontCodedBlock.Builder.init(
        BlockWriter.init(default_buf[0..]),
        default_scratch[0..],
    );
    defer default_builder.deinit();
    var metadata_builder = try ZeroMetadataFrontCodedBlock.Builder.init(
        BlockWriter.init(metadata_buf[0..]),
        metadata_scratch[0..],
    );
    defer metadata_builder.deinit();

    for (sample_entries) |entry| {
        try default_builder.add(entry.key, entry.value);
        try metadata_builder.add(entry.key, entry.value);
    }

    try std.testing.expectEqualSlices(
        u8,
        default_builder.usedBytes(),
        metadata_builder.usedBytes(),
    );
}

test "Codec: FrontCodedBlock find returns matching entries" {
    var buf = [_]u8{0} ** 1024;
    var builder_scratch: [256]u8 = undefined;
    var builder = try FrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), builder_scratch[0..]);
    defer builder.deinit();

    for (sample_entries) |entry| {
        try builder.add(entry.key, entry.value);
    }

    var reader = try builder.reader();
    defer reader.deinit();

    var first_scratch: [256]u8 = undefined;
    var first = (try reader.find(sample_entries[0].key, first_scratch[0..], StrSliceCmp.cmp, {})).?;
    defer first.deinit();
    try std.testing.expectEqualStrings(sample_entries[0].key, first.scratchKey());
    try std.testing.expectEqualStrings(sample_entries[0].value, try first.value());

    var middle_scratch: [256]u8 = undefined;
    var middle = (try reader.find(sample_entries[2].key, middle_scratch[0..], StrSliceCmp.cmp, {})).?;
    defer middle.deinit();
    try std.testing.expectEqualStrings(sample_entries[2].key, middle.scratchKey());
    try std.testing.expectEqualStrings(sample_entries[2].value, try middle.value());

    var last_scratch: [256]u8 = undefined;
    var last = (try reader.find(sample_entries[3].key, last_scratch[0..], StrSliceCmp.cmp, {})).?;
    defer last.deinit();
    try std.testing.expectEqualStrings(sample_entries[3].key, last.scratchKey());
    try std.testing.expectEqualStrings(sample_entries[3].value, try last.value());
}

test "Codec: FrontCodedBlock find returns null for missing keys" {
    var buf = [_]u8{0} ** 1024;
    var builder_scratch: [256]u8 = undefined;
    var builder = try FrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), builder_scratch[0..]);
    defer builder.deinit();

    for (sample_entries) |entry| {
        try builder.add(entry.key, entry.value);
    }

    var reader = try builder.reader();
    defer reader.deinit();

    var before_scratch: [256]u8 = undefined;
    try std.testing.expectEqual(null, try reader.find("aaa", before_scratch[0..], StrSliceCmp.cmp, {}));

    var between_scratch: [256]u8 = undefined;
    try std.testing.expectEqual(null, try reader.find("filesystem_a", between_scratch[0..], StrSliceCmp.cmp, {}));

    var after_scratch: [256]u8 = undefined;
    try std.testing.expectEqual(null, try reader.find("z", after_scratch[0..], StrSliceCmp.cmp, {}));
}

test "Codec: FrontCodedBlock find handles empty block" {
    var buf = [_]u8{0} ** 128;
    var builder_scratch: [32]u8 = undefined;
    var builder = try FrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), builder_scratch[0..]);
    defer builder.deinit();

    var reader = try builder.reader();
    defer reader.deinit();

    var read_scratch: [32]u8 = undefined;
    try std.testing.expectEqual(null, try reader.find("abc", read_scratch[0..], StrSliceCmp.cmp, {}));
}

test "Codec: FrontCodedBlock find rejects unordered comparison" {
    var buf = [_]u8{0} ** 128;
    var builder_scratch: [32]u8 = undefined;
    var builder = try FrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), builder_scratch[0..]);
    defer builder.deinit();

    try builder.add("abc", "v0");

    var reader = try builder.reader();
    defer reader.deinit();

    var read_scratch: [32]u8 = undefined;
    try std.testing.expectError(error.Unordered, reader.find("abc", read_scratch[0..], UnorderedSliceCmp.cmp, {}));
}

test "Codec: FrontCodedBlock iterator ignores padding after used bytes" {
    var buf = [_]u8{0} ** 1024;
    var builder_scratch: [256]u8 = undefined;
    var builder = try FrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), builder_scratch[0..]);
    defer builder.deinit();

    for (sample_entries) |entry| {
        try builder.add(entry.key, entry.value);
    }

    const used_bytes = builder.block_writer.used().len;
    var reader = try FrontCodedBlock.Reader.init(BlockReader.init(buf[0..]));
    defer reader.deinit();

    try std.testing.expectEqual(used_bytes, try reader.usedBytes());

    var read_scratch: [256]u8 = undefined;
    var itr = try reader.iterator(read_scratch[0..]);
    defer itr.deinit();

    var index: usize = 0;
    while (!itr.done()) : (index += 1) {
        try std.testing.expect(index < sample_entries.len);
        try std.testing.expectEqualStrings(sample_entries[index].key, itr.scratchKey());
        try std.testing.expectEqualStrings(sample_entries[index].value, try itr.value());
        try itr.next();
    }

    try std.testing.expectEqual(sample_entries.len, index);
}

test "Codec: FrontCodedBlock stores shared prefix entries" {
    var buf = [_]u8{0} ** 1024;
    var scratch: [256]u8 = undefined;
    var builder = try FrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), scratch[0..]);
    defer builder.deinit();

    const first_size = builder.sizeAfterAdd("filesystem", "v0");
    try builder.add("filesystem", "v0");
    try std.testing.expectEqual(first_size, builder.block_writer.used().len);

    const second_size = builder.sizeAfterAdd("filesystem_cache", "v1");
    try builder.add("filesystem_cache", "v1");
    try std.testing.expectEqual(second_size, builder.block_writer.used().len);

    var reader = try builder.reader();
    defer reader.deinit();

    var read_scratch: [256]u8 = undefined;
    var itr = try reader.iterator(read_scratch[0..]);
    defer itr.deinit();

    try std.testing.expectEqualStrings("filesystem", itr.scratchKey());
    try itr.next();
    try std.testing.expectEqualStrings("filesystem_cache", itr.scratchKey());

    const expected_second_suffix_len = "_cache".len;
    const expected_second_size = first_size + ENTRY_HEADER_SIZE + expected_second_suffix_len + "v1".len;
    try std.testing.expectEqual(expected_second_size, second_size);
}

test "Codec: FrontCodedBlock rejects too-small block buffer" {
    var buf = [_]u8{0} ** (HEADER_SIZE + ENTRY_HEADER_SIZE + 3);
    var scratch: [16]u8 = undefined;
    var builder = try FrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), scratch[0..]);
    defer builder.deinit();

    try std.testing.expect(!builder.canAdd("abcd", "v"));
    try std.testing.expectError(error.BufferTooSmall, builder.add("abcd", "v"));
}

test "Codec: FrontCodedBlock rejects too-small scratch buffer" {
    var buf = [_]u8{0} ** 128;
    var scratch = [_]u8{0} ** 3;
    var builder = try FrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), scratch[0..]);
    defer builder.deinit();

    try std.testing.expect(!builder.canAdd("abcd", "v"));
    try std.testing.expectError(error.BufferTooSmall, builder.add("abcd", "v"));
}

test "Codec: FrontCodedBlock iterator requires max-key scratch" {
    var buf = [_]u8{0} ** 256;
    var builder_scratch: [32]u8 = undefined;
    var builder = try FrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), builder_scratch[0..]);
    defer builder.deinit();

    try builder.add("abc", "v0");
    try builder.add("abcdef", "v1");

    var reader = try builder.reader();
    defer reader.deinit();

    var read_scratch = [_]u8{0} ** 5;
    var itr = try reader.iterator(read_scratch[0..]);
    defer itr.deinit();

    try std.testing.expectEqualStrings("abc", itr.scratchKey());
    try std.testing.expectError(error.BufferTooSmall, itr.next());
}

test "Codec: FrontCodedBlock rejects first entry with shared prefix" {
    var buf = [_]u8{0} ** 256;
    var builder_scratch: [32]u8 = undefined;
    var builder = try FrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), builder_scratch[0..]);
    defer builder.deinit();

    try builder.add("abc", "v0");

    const first_hdr = entryHeaderAt(buf[0..], HEADER_SIZE);
    first_hdr.shared_len.set(1);

    var reader = try FrontCodedBlock.Reader.init(BlockReader.init(builder.block_writer.used()));
    defer reader.deinit();

    var read_scratch: [32]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, reader.iterator(read_scratch[0..]));
}

test "Codec: FrontCodedBlock rejects entry with shared prefix longer than previous key" {
    var buf = [_]u8{0} ** 256;
    var builder_scratch: [32]u8 = undefined;
    var builder = try FrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), builder_scratch[0..]);
    defer builder.deinit();

    try builder.add("abc", "v0");
    try builder.add("abcd", "v1");

    const second_offset = HEADER_SIZE + ENTRY_HEADER_SIZE + "abc".len + "v0".len;
    const second_hdr = entryHeaderAt(buf[0..], second_offset);
    second_hdr.shared_len.set("abc".len + 1);

    var reader = try FrontCodedBlock.Reader.init(BlockReader.init(builder.block_writer.used()));
    defer reader.deinit();

    var read_scratch: [32]u8 = undefined;
    var itr = try reader.iterator(read_scratch[0..]);
    defer itr.deinit();

    try std.testing.expectEqualStrings("abc", itr.scratchKey());
    try std.testing.expectError(error.BufferTooSmall, itr.next());
}

test "Codec: FrontCodedBlock rejects entry count overflow" {
    var buf = [_]u8{0} ** 2048;
    var scratch: [1]u8 = undefined;
    var builder = try FrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), scratch[0..]);
    defer builder.deinit();

    for (0..std.math.maxInt(u8)) |_| {
        try std.testing.expect(builder.canAdd("", ""));
        try builder.add("", "");
    }

    try std.testing.expect(!builder.canAdd("", ""));
    try std.testing.expectError(error.BufferTooSmall, builder.add("", ""));
}

test "Codec: FrontCodedBlock rejects index overflow" {
    var buf = [_]u8{0} ** 512;
    var scratch = [_]u8{0} ** 256;
    var key = [_]u8{'a'} ** 256;
    var builder = try SmallIndexFrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), scratch[0..]);
    defer builder.deinit();

    try std.testing.expect(!builder.canAdd(key[0..], "v"));
    try std.testing.expectError(error.BufferTooSmall, builder.add(key[0..], "v"));
}

test "Codec: FrontCodedBlock rejects block size overflow" {
    var buf = [_]u8{0} ** 512;
    var scratch = [_]u8{0} ** 256;
    var first_key = [_]u8{'a'} ** 200;
    var second_key = [_]u8{'b'} ** 200;
    var builder = try SmallBlockSizeFrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), scratch[0..]);
    defer builder.deinit();

    try std.testing.expect(builder.canAdd(first_key[0..], "v"));
    try builder.add(first_key[0..], "v");

    try std.testing.expect(!builder.canAdd(second_key[0..], "v"));
    try std.testing.expectError(error.BufferTooSmall, builder.add(second_key[0..], "v"));
}

test "Codec: FrontCodedBlock reader rejects used bytes smaller than header" {
    var buf = [_]u8{0} ** 128;
    var scratch: [32]u8 = undefined;
    var builder = try FrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), scratch[0..]);
    defer builder.deinit();

    try builder.add("abc", "v0");

    const hdr = blockHeaderAt(buf[0..]);
    hdr.used_bytes.set(HEADER_SIZE - 1);

    try std.testing.expectError(error.BufferTooSmall, FrontCodedBlock.Reader.init(BlockReader.init(builder.block_writer.used())));
}

test "Codec: FrontCodedBlock reader rejects used bytes beyond view" {
    var buf = [_]u8{0} ** 128;
    var scratch: [32]u8 = undefined;
    var builder = try FrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), scratch[0..]);
    defer builder.deinit();

    try builder.add("abc", "v0");

    const hdr = blockHeaderAt(buf[0..]);
    hdr.used_bytes.set(@intCast(builder.block_writer.used().len + 1));

    try std.testing.expectError(error.BufferTooSmall, FrontCodedBlock.Reader.init(BlockReader.init(builder.block_writer.used())));
}

test "Codec: FrontCodedBlock reader rejects truncated entry" {
    var buf = [_]u8{0} ** 128;
    var scratch: [32]u8 = undefined;
    var builder = try FrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), scratch[0..]);
    defer builder.deinit();

    try builder.add("abc", "v0");

    const hdr = blockHeaderAt(buf[0..]);
    hdr.used_bytes.set(@intCast(builder.block_writer.used().len - 1));

    try std.testing.expectError(error.BufferTooSmall, FrontCodedBlock.Reader.init(BlockReader.init(builder.block_writer.used())));
}

test "Codec: FrontCodedBlock reader rejects entry count mismatch" {
    var buf = [_]u8{0} ** 128;
    var scratch: [32]u8 = undefined;
    var builder = try FrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), scratch[0..]);
    defer builder.deinit();

    try builder.add("abc", "v0");

    const hdr = blockHeaderAt(buf[0..]);
    hdr.entry_count.set(2);

    try std.testing.expectError(error.BufferTooSmall, FrontCodedBlock.Reader.init(BlockReader.init(builder.block_writer.used())));
}

test "Codec: FrontCodedBlock reader rejects trailing bytes inside used bytes" {
    var buf = [_]u8{0} ** 128;
    var scratch: [32]u8 = undefined;
    var builder = try FrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), scratch[0..]);
    defer builder.deinit();

    try builder.add("abc", "v0");

    const used_bytes = builder.block_writer.used().len;
    const hdr = blockHeaderAt(buf[0..]);
    hdr.used_bytes.set(@intCast(used_bytes + 1));

    try std.testing.expectError(error.BufferTooSmall, FrontCodedBlock.Reader.init(BlockReader.init(buf[0 .. used_bytes + 1])));
}

test "Codec: FrontCodedBlock iterator borrows reader view" {
    counting_view_deinit_count = 0;

    var buf = [_]u8{0} ** 128;
    var scratch: [32]u8 = undefined;
    var builder = try CountingViewFrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), scratch[0..]);
    defer builder.deinit();

    try builder.add("abc", "v0");

    var reader = try builder.reader();

    var read_scratch: [32]u8 = undefined;
    var itr = try reader.iterator(read_scratch[0..]);
    itr.deinit();

    try std.testing.expectEqual(@as(usize, 0), counting_view_deinit_count);

    reader.deinit();
    try std.testing.expectEqual(@as(usize, 1), counting_view_deinit_count);
}

test "Codec: FrontCodedBlock builder uses writer contract without buf field" {
    var buf = [_]u8{0} ** 128;
    var scratch: [32]u8 = undefined;
    var builder = try NoBufWriterFrontCodedBlock.Builder.init(NoBufFieldWriter.init(buf[0..]), scratch[0..]);
    defer builder.deinit();

    try builder.add("abc", "v0");

    var reader = try builder.reader();
    defer reader.deinit();

    var read_scratch: [32]u8 = undefined;
    var itr = try reader.iterator(read_scratch[0..]);
    defer itr.deinit();

    try std.testing.expectEqualStrings("abc", itr.scratchKey());
    try std.testing.expectEqualStrings("v0", try itr.value());
}
