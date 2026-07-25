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

const keys = fullaz.keys;
const BlockWriter = keys.memory_block.MemoryBlockWriter(u8);
const BlockReader = keys.memory_block.MemoryBlockView(u8);

const FrontCodedBlock = keys.front_coded_block2.FrontCodedBlock2(
    u8,
    u16,
    u32,
    BlockWriter,
    BlockReader,
    std.builtin.Endian.little,
    true,
    StrCmp.cmp,
    void,
);

const SmallIndexFrontCodedBlock = keys.front_coded_block2.FrontCodedBlock2(
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

const SmallBlockSizeFrontCodedBlock = keys.front_coded_block2.FrontCodedBlock2(
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
    items: []const u8,

    pub fn init(items: []const u8) Self {
        return .{ .items = items };
    }

    pub fn deinit(_: *Self) void {
        counting_view_deinit_count += 1;
    }

    pub fn at(self: *const Self, index: usize, length: usize) []const u8 {
        return self.items[index .. index + length];
    }

    pub fn slice(self: *const Self) []const u8 {
        return self.items;
    }

    pub fn len(self: *const Self) usize {
        return self.items.len;
    }
};

const CountingViewFrontCodedBlock = keys.front_coded_block2.FrontCodedBlock2(
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

const NoBufWriterFrontCodedBlock = keys.front_coded_block2.FrontCodedBlock2(
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

test "Keys: FrontCodedBlock2 writes header metadata" {
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

    try std.testing.expectEqual(sample_entries.len, reader.entryCount());
    try std.testing.expectEqual(expectedUsedBytes(sample_entries[0..]), reader.usedBytes());
    try std.testing.expectEqual(maxKeyLen(sample_entries[0..]), reader.maxKeyLen());
    try std.testing.expectEqual(reader.usedBytes(), builder.block_writer.used().len);
}

test "Keys: FrontCodedBlock2 supports empty block" {
    var buf = [_]u8{0} ** 128;
    var scratch: [32]u8 = undefined;
    var builder = try FrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), scratch[0..]);
    defer builder.deinit();

    var reader = try builder.reader();
    defer reader.deinit();

    try std.testing.expectEqual(@as(usize, 0), reader.entryCount());
    try std.testing.expectEqual(@as(usize, HEADER_SIZE), reader.usedBytes());
    try std.testing.expectEqual(@as(usize, 0), reader.maxKeyLen());

    var read_scratch: [32]u8 = undefined;
    var itr = try reader.iterator(read_scratch[0..]);
    defer itr.deinit();

    try std.testing.expect(itr.done());
}

test "Keys: FrontCodedBlock2 iterator rebuilds keys with caller scratch" {
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

test "Keys: FrontCodedBlock2 iterator ignores padding after used bytes" {
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

    try std.testing.expectEqual(used_bytes, reader.usedBytes());

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

test "Keys: FrontCodedBlock2 stores shared prefix entries" {
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

test "Keys: FrontCodedBlock2 rejects too-small block buffer" {
    var buf = [_]u8{0} ** (HEADER_SIZE + ENTRY_HEADER_SIZE + 3);
    var scratch: [16]u8 = undefined;
    var builder = try FrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), scratch[0..]);
    defer builder.deinit();

    try std.testing.expect(!builder.canAdd("abcd", "v"));
    try std.testing.expectError(error.BufferTooSmall, builder.add("abcd", "v"));
}

test "Keys: FrontCodedBlock2 rejects too-small scratch buffer" {
    var buf = [_]u8{0} ** 128;
    var scratch = [_]u8{0} ** 3;
    var builder = try FrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), scratch[0..]);
    defer builder.deinit();

    try std.testing.expect(!builder.canAdd("abcd", "v"));
    try std.testing.expectError(error.BufferTooSmall, builder.add("abcd", "v"));
}

test "Keys: FrontCodedBlock2 iterator requires max-key scratch" {
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

test "Keys: FrontCodedBlock2 rejects first entry with shared prefix" {
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

test "Keys: FrontCodedBlock2 rejects entry with shared prefix longer than previous key" {
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

test "Keys: FrontCodedBlock2 rejects entry count overflow" {
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

test "Keys: FrontCodedBlock2 rejects index overflow" {
    var buf = [_]u8{0} ** 512;
    var scratch = [_]u8{0} ** 256;
    var key = [_]u8{'a'} ** 256;
    var builder = try SmallIndexFrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), scratch[0..]);
    defer builder.deinit();

    try std.testing.expect(!builder.canAdd(key[0..], "v"));
    try std.testing.expectError(error.BufferTooSmall, builder.add(key[0..], "v"));
}

test "Keys: FrontCodedBlock2 rejects block size overflow" {
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

test "Keys: FrontCodedBlock2 reader rejects used bytes smaller than header" {
    var buf = [_]u8{0} ** 128;
    var scratch: [32]u8 = undefined;
    var builder = try FrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), scratch[0..]);
    defer builder.deinit();

    try builder.add("abc", "v0");

    const hdr = blockHeaderAt(buf[0..]);
    hdr.used_bytes.set(HEADER_SIZE - 1);

    try std.testing.expectError(error.BufferTooSmall, FrontCodedBlock.Reader.init(BlockReader.init(builder.block_writer.used())));
}

test "Keys: FrontCodedBlock2 reader rejects used bytes beyond view" {
    var buf = [_]u8{0} ** 128;
    var scratch: [32]u8 = undefined;
    var builder = try FrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), scratch[0..]);
    defer builder.deinit();

    try builder.add("abc", "v0");

    const hdr = blockHeaderAt(buf[0..]);
    hdr.used_bytes.set(@intCast(builder.block_writer.used().len + 1));

    try std.testing.expectError(error.BufferTooSmall, FrontCodedBlock.Reader.init(BlockReader.init(builder.block_writer.used())));
}

test "Keys: FrontCodedBlock2 reader rejects truncated entry" {
    var buf = [_]u8{0} ** 128;
    var scratch: [32]u8 = undefined;
    var builder = try FrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), scratch[0..]);
    defer builder.deinit();

    try builder.add("abc", "v0");

    const hdr = blockHeaderAt(buf[0..]);
    hdr.used_bytes.set(@intCast(builder.block_writer.used().len - 1));

    try std.testing.expectError(error.BufferTooSmall, FrontCodedBlock.Reader.init(BlockReader.init(builder.block_writer.used())));
}

test "Keys: FrontCodedBlock2 reader rejects entry count mismatch" {
    var buf = [_]u8{0} ** 128;
    var scratch: [32]u8 = undefined;
    var builder = try FrontCodedBlock.Builder.init(BlockWriter.init(buf[0..]), scratch[0..]);
    defer builder.deinit();

    try builder.add("abc", "v0");

    const hdr = blockHeaderAt(buf[0..]);
    hdr.entry_count.set(2);

    try std.testing.expectError(error.BufferTooSmall, FrontCodedBlock.Reader.init(BlockReader.init(builder.block_writer.used())));
}

test "Keys: FrontCodedBlock2 reader rejects trailing bytes inside used bytes" {
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

test "Keys: FrontCodedBlock2 iterator borrows reader view" {
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

test "Keys: FrontCodedBlock2 builder uses writer contract without buf field" {
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
