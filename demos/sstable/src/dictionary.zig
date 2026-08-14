const std = @import("std");
const fullaz = @import("fullaz");

pub const max_entries: usize = 4_096;
pub const max_key_bytes: usize = 128;
pub const max_value_bytes: usize = 256;
pub const comparator_id: u32 = 1;

const Format = fullaz.sstable.SstableFormat(u64, u32, u32, .little);
const Log = fullaz.device.MemoryLog(u64);
const Writer = fullaz.sstable.Writer(Format, Log, compareBytes, void);
const Reader = fullaz.sstable.Reader(Format, Log, compareBytes, void);
const Footer = fullaz.sstable.Footer(Format);
const EntryMetadata = fullaz.sstable.EntryMetadata(Format);

pub const ReadScratch = Reader.ReadScratchType;

pub const settings: fullaz.sstable.Settings = .{
    .max_entries_per_coded_block = max_entries,
    .max_coded_block_bytes = 512,
    .data_page_bytes = 2 * 1024,
    .index_page_bytes = 1024,
    .max_key_bytes = max_key_bytes,
    .max_value_bytes = max_value_bytes,
};

const Entry = struct {
    key: []u8,
    value: []u8,
    metadata: EntryMetadata,

    fn init(
        allocator: std.mem.Allocator,
        key: []const u8,
        value: []const u8,
        metadata: EntryMetadata,
    ) !Entry {
        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        return .{
            .key = owned_key,
            .value = try allocator.dupe(u8, value),
            .metadata = metadata,
        };
    }

    fn clone(self: Entry, allocator: std.mem.Allocator) !Entry {
        return init(allocator, self.key, self.value, self.metadata);
    }

    fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

const Table = struct {
    log: Log,
    reader: Reader,

    fn init(allocator: std.mem.Allocator, entries: []const Entry) Dictionary.Error!*Table {
        std.debug.assert(entries.len > 0);

        const table = try allocator.create(Table);
        errdefer allocator.destroy(table);
        table.log = try Log.init(allocator);
        errdefer table.log.deinit();

        var writer = try Writer.init(
            allocator,
            &table.log,
            .{
                .entry_count = entries.len,
                .comparator_id = comparator_id,
                .settings = settings,
            },
            {},
        );
        defer writer.deinit();

        for (entries) |entry| {
            try writer.addWithMetadata(entry.key, entry.value, entry.metadata);
        }
        try writer.finish();

        table.reader = try Reader.init(
            allocator,
            &table.log,
            .{
                .comparator_id = comparator_id,
                .index_backend = .memory,
            },
            {},
        );
        return table;
    }

    fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        self.reader.deinit();
        self.log.deinit();
        allocator.destroy(self);
    }
};

/// A small UTF-8 byte dictionary rebuilt as one immutable SSTable per mutation.
pub const Dictionary = struct {
    const Self = @This();

    pub const InputEntry = struct {
        key: []const u8,
        value: []const u8,
        flags: fullaz.sstable.EntryFlags = .value,
        lsn: Format.Lsn = 0,
    };
    pub const Lookup = Reader.Entry;

    /// File regions emitted by the SSTable writer.
    pub const Layout = struct {
        entry_count: usize,
        tombstone_count: usize,
        min_lsn: usize,
        max_lsn: usize,
        data_offset: usize,
        data_bytes: usize,
        data_page_count: usize,
        data_page_max_bytes: usize,
        index_entry_count: usize,
        bloom_offset: usize,
        bloom_bytes: usize,
        bloom_bit_count: usize,
        bloom_hash_count: usize,
        index_offset: usize,
        index_page_bytes: usize,
        index_page_count: usize,
        index_root_page_id: usize,
        footer_offset: usize,
        footer_bytes: usize,
        trailer_bytes: usize,
        file_bytes: usize,
    };

    pub const Error = Writer.Error || Reader.Error || error{
        InvalidUtf8,
        TooManyEntries,
        KeyTooLarge,
        ValueTooLarge,
    };

    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    table: ?*Table = null,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        if (self.table) |table| {
            table.deinit(self.allocator);
        }
        deinitEntries(self.allocator, &self.entries);
    }

    /// Inserts or replaces a valid UTF-8 key/value pair and rebuilds its table.
    pub fn set(self: *Self, key: []const u8, value: []const u8) Error!void {
        try validateEntry(key, value);

        var entries = try self.cloneEntries();
        errdefer deinitEntries(self.allocator, &entries);
        const location = findEntry(entries.items, key);
        if (location.found) {
            const replacement = try self.allocator.dupe(u8, value);
            self.allocator.free(entries.items[location.index].value);
            entries.items[location.index].value = replacement;
            entries.items[location.index].metadata = .{
                .flags = .value,
                .lsn = 0,
            };
        } else {
            if (entries.items.len == max_entries) {
                return Error.TooManyEntries;
            }
            const entry = try Entry.init(self.allocator, key, value, .{
                .flags = .value,
                .lsn = 0,
            });
            entries.insert(self.allocator, location.index, entry) catch |err| {
                entry.deinit(self.allocator);
                return err;
            };
        }
        try self.replace(entries);
    }

    /// Replaces every entry with an ordered input set, rebuilding the table once.
    pub fn replaceAll(self: *Self, input: []const InputEntry) Error!void {
        if (input.len > max_entries) {
            return Error.TooManyEntries;
        }

        var entries: std.ArrayList(Entry) = .empty;
        errdefer deinitEntries(self.allocator, &entries);
        for (input, 0..) |entry, index| {
            try validateEntry(entry.key, entry.value);
            if (index > 0) {
                switch (compareBytes({}, entries.items[index - 1].key, entry.key)) {
                    .lt => {},
                    .eq => {
                        return Error.DuplicateKey;
                    },
                    .gt, .unordered => {
                        return Error.UnorderedKey;
                    },
                }
            }
            const owned = try Entry.init(self.allocator, entry.key, entry.value, .{
                .flags = entry.flags,
                .lsn = entry.lsn,
            });
            entries.append(self.allocator, owned) catch |err| {
                owned.deinit(self.allocator);
                return err;
            };
        }
        try self.replace(entries);
    }

    /// Removes `key` and returns whether the dictionary changed.
    pub fn remove(self: *Self, key: []const u8) Error!bool {
        if (!std.unicode.utf8ValidateSlice(key)) {
            return Error.InvalidUtf8;
        }

        var entries = try self.cloneEntries();
        errdefer deinitEntries(self.allocator, &entries);
        const location = findEntry(entries.items, key);
        if (!location.found) {
            return false;
        }
        entries.items[location.index].deinit(self.allocator);
        _ = entries.orderedRemove(location.index);
        try self.replace(entries);
        return true;
    }

    /// The returned entry borrows `scratch` and is invalidated by the next lookup.
    pub fn lookup(self: *Self, key: []const u8, scratch: *ReadScratch) Error!?Lookup {
        if (!std.unicode.utf8ValidateSlice(key)) {
            return Error.InvalidUtf8;
        }
        const table = self.table orelse return null;
        return try table.reader.find(key, scratch);
    }

    /// Borrows the complete immutable SSTable image until the next mutation or deinit.
    pub fn image(self: *const Self) []const u8 {
        const table = self.table orelse return &.{};
        return table.log.buf.items;
    }

    /// Returns the regions of the current image, or null when the dictionary is empty.
    pub fn layout(self: *const Self) ?Layout {
        const table = self.table orelse return null;
        const info = table.reader.footer;
        const footer_bytes = info.settings.index_page_bytes;
        const trailer_bytes = @sizeOf(Footer.Trailer);
        const file_bytes = table.log.buf.items.len;
        var tombstone_count: usize = 0;
        for (self.entries.items) |entry| {
            if (entry.metadata.flags == .tombstone) {
                tombstone_count += 1;
            }
        }
        std.debug.assert(file_bytes >= footer_bytes + trailer_bytes);

        return .{
            .entry_count = @intCast(info.entry_count),
            .tombstone_count = tombstone_count,
            .min_lsn = @intCast(info.min_lsn),
            .max_lsn = @intCast(info.max_lsn),
            .data_offset = @intCast(info.data_offset),
            .data_bytes = @intCast(info.data_length),
            .data_page_count = @intCast(info.data_page_count),
            .data_page_max_bytes = info.settings.data_page_bytes,
            // The index has one fence key per flushed data page.
            .index_entry_count = @intCast(info.data_page_count),
            .bloom_offset = @intCast(info.bloom_offset),
            .bloom_bytes = @intCast(info.bloom_length),
            .bloom_bit_count = @intCast(info.bloom_bit_count),
            .bloom_hash_count = @intCast(info.bloom_hash_count),
            .index_offset = @intCast(info.index_offset),
            .index_page_bytes = @intCast(info.index_page_size),
            .index_page_count = @intCast(info.index_page_count),
            .index_root_page_id = @intCast(info.index_root_page_id),
            .footer_offset = file_bytes - footer_bytes - trailer_bytes,
            .footer_bytes = footer_bytes,
            .trailer_bytes = trailer_bytes,
            .file_bytes = file_bytes,
        };
    }

    fn cloneEntries(self: *const Self) std.mem.Allocator.Error!std.ArrayList(Entry) {
        var entries: std.ArrayList(Entry) = .empty;
        errdefer deinitEntries(self.allocator, &entries);
        for (self.entries.items) |entry| {
            const copy = try entry.clone(self.allocator);
            entries.append(self.allocator, copy) catch |err| {
                copy.deinit(self.allocator);
                return err;
            };
        }
        return entries;
    }

    fn replace(self: *Self, entries: std.ArrayList(Entry)) Error!void {
        const table = if (entries.items.len == 0)
            null
        else
            try Table.init(self.allocator, entries.items);
        const previous_table = self.table;
        deinitEntries(self.allocator, &self.entries);
        self.entries = entries;
        self.table = table;
        if (previous_table) |previous| {
            previous.deinit(self.allocator);
        }
    }
};

fn compareBytes(_: void, a: []const u8, b: []const u8) fullaz.core.algorithm.Order {
    return switch (std.mem.order(u8, a, b)) {
        .lt => .lt,
        .eq => .eq,
        .gt => .gt,
    };
}

fn findEntry(entries: []const Entry, key: []const u8) struct { index: usize, found: bool } {
    var index: usize = 0;
    while (index < entries.len) : (index += 1) {
        switch (compareBytes({}, entries[index].key, key)) {
            .lt => {},
            .eq => return .{ .index = index, .found = true },
            .gt, .unordered => return .{ .index = index, .found = false },
        }
    }
    return .{ .index = index, .found = false };
}

fn deinitEntries(allocator: std.mem.Allocator, entries: *std.ArrayList(Entry)) void {
    for (entries.items) |entry| {
        entry.deinit(allocator);
    }
    entries.deinit(allocator);
}

fn validateEntry(key: []const u8, value: []const u8) Dictionary.Error!void {
    if (!std.unicode.utf8ValidateSlice(key) or !std.unicode.utf8ValidateSlice(value)) {
        return Dictionary.Error.InvalidUtf8;
    }
    if (key.len > max_key_bytes) {
        return Dictionary.Error.KeyTooLarge;
    }
    if (value.len > max_value_bytes) {
        return Dictionary.Error.ValueTooLarge;
    }
}

test "dictionary rebuilds sorted entries" {
    var dictionary = Dictionary.init(std.testing.allocator);
    defer dictionary.deinit();

    try dictionary.set("zebra", "black and white");
    try dictionary.set("ant", "small");
    try dictionary.set("zebra", "striped");

    var data_page: [settings.data_page_bytes]u8 = undefined;
    var key: [max_key_bytes]u8 = undefined;
    var scratch = ReadScratch{ .data_page = &data_page, .key = &key };
    try std.testing.expectEqualSlices(u8, "small", (try dictionary.lookup("ant", &scratch)).?.value);
    try std.testing.expectEqualSlices(u8, "striped", (try dictionary.lookup("zebra", &scratch)).?.value);
    try std.testing.expect(try dictionary.remove("ant"));
    try std.testing.expect((try dictionary.lookup("ant", &scratch)) == null);
}

test "dictionary exposes its SSTable file layout" {
    var dictionary = Dictionary.init(std.testing.allocator);
    defer dictionary.deinit();

    try std.testing.expect(dictionary.layout() == null);
    try std.testing.expectEqualSlices(u8, &.{}, dictionary.image());

    try dictionary.set("ant", "small");
    try dictionary.set("zebra", "striped");

    const layout = dictionary.layout().?;
    try std.testing.expectEqual(@as(usize, 2), layout.entry_count);
    try std.testing.expectEqual(@as(usize, 0), layout.data_offset);
    try std.testing.expect(layout.data_bytes < settings.data_page_bytes);
    try std.testing.expectEqual(@as(usize, 1), layout.data_page_count);
    try std.testing.expectEqual(settings.data_page_bytes, layout.data_page_max_bytes);
    try std.testing.expectEqual(@as(usize, 1), layout.index_entry_count);
    try std.testing.expectEqual(layout.data_offset + layout.data_bytes, layout.bloom_offset);
    try std.testing.expectEqual(layout.bloom_offset + layout.bloom_bytes, layout.index_offset);
    try std.testing.expectEqual(
        layout.index_offset + layout.index_page_bytes * layout.index_page_count,
        layout.footer_offset,
    );
    try std.testing.expectEqual(
        layout.footer_offset + layout.footer_bytes + layout.trailer_bytes,
        layout.file_bytes,
    );
    try std.testing.expectEqual(layout.file_bytes, dictionary.image().len);
}

test "dictionary replaces an ordered entry set atomically" {
    var dictionary = Dictionary.init(std.testing.allocator);
    defer dictionary.deinit();
    try dictionary.set("zebra", "striped");

    const input = [_]Dictionary.InputEntry{
        .{ .key = "ant", .value = "small" },
        .{ .key = "otter", .value = "playful" },
    };
    try dictionary.replaceAll(&input);

    var data_page: [settings.data_page_bytes]u8 = undefined;
    var key: [max_key_bytes]u8 = undefined;
    var scratch = ReadScratch{ .data_page = &data_page, .key = &key };
    try std.testing.expectEqualSlices(u8, "playful", (try dictionary.lookup("otter", &scratch)).?.value);
    try std.testing.expect((try dictionary.lookup("zebra", &scratch)) == null);
}

test "dictionary builds a near-megabyte lexicon table" {
    const entry_count = 3_500;
    const key_bytes = "lexeme-0000".len;
    const value_bytes = 220;
    const value_fill = "This generated definition fills SSTable data pages and demonstrates indexed immutable storage. ";
    const input = try std.testing.allocator.alloc(Dictionary.InputEntry, entry_count);
    defer std.testing.allocator.free(input);
    const source = try std.testing.allocator.alloc(
        u8,
        entry_count * (key_bytes + value_bytes),
    );
    defer std.testing.allocator.free(source);

    var offset: usize = 0;
    for (input, 0..) |*entry, index| {
        const key = source[offset .. offset + key_bytes];
        offset += key.len;
        _ = try std.fmt.bufPrint(key, "lexeme-{d:0>4}", .{index});
        const value = source[offset .. offset + value_bytes];
        offset += value.len;
        const prefix = try std.fmt.bufPrint(value, "Generated lexicon definition {d}. ", .{index});
        var filled = prefix.len;
        while (filled < value.len) {
            const fill_len = @min(value.len - filled, value_fill.len);
            @memcpy(value[filled .. filled + fill_len], value_fill[0..fill_len]);
            filled += fill_len;
        }
        entry.* = .{
            .key = key,
            .value = if (index % 17 == 0) "" else value,
            .flags = if (index % 17 == 0) .tombstone else .value,
            .lsn = @intCast(index + 1),
        };
    }

    var dictionary = Dictionary.init(std.testing.allocator);
    defer dictionary.deinit();
    try dictionary.replaceAll(input);

    const layout = dictionary.layout().?;
    try std.testing.expectEqual(@as(usize, 206), layout.tombstone_count);
    try std.testing.expect(layout.file_bytes > 800 * 1024);
    try std.testing.expect(layout.file_bytes <= 1024 * 1024);
    try std.testing.expect(layout.data_page_count > 100);
    try std.testing.expect(layout.index_page_count > 1);
    try std.testing.expectEqual(layout.data_page_count, layout.index_entry_count);

    var data_page: [settings.data_page_bytes]u8 = undefined;
    var key: [max_key_bytes]u8 = undefined;
    var scratch = ReadScratch{ .data_page = &data_page, .key = &key };
    const tombstone = (try dictionary.lookup("lexeme-0000", &scratch)).?;
    try std.testing.expectEqual(.tombstone, tombstone.metadata.flags);
    try std.testing.expectEqual(@as(u64, 1), tombstone.metadata.lsn);
}
