const std = @import("std");
const fullaz = @import("fullaz");
const sstable = @import("sstable");

const Dictionary = sstable.dictionary.Dictionary;
const allocator = std.heap.wasm_allocator;
const large_entry_count = 3_500;
const large_key_bytes = "lexeme-0000".len;
const large_value_bytes = 220;
const large_value_fill = "This generated definition fills SSTable data pages and demonstrates indexed immutable storage. ";

pub const panic = std.debug.FullPanic(struct {
    fn f(_: []const u8, _: ?usize) noreturn {
        @trap();
    }
}.f);

var dictionary = Dictionary.init(allocator);
var staging: ?Dictionary = null;
var last_error: []const u8 = "";
var lookup_result: []const u8 = &.{};
var lookup_flags: u8 = @intFromEnum(fullaz.sstable.EntryFlags.value);
var lookup_lsn: u64 = 0;
var data_page: [sstable.dictionary.settings.data_page_bytes]u8 = undefined;
var key: [sstable.dictionary.max_key_bytes]u8 = undefined;
var layout_snapshot: Dictionary.Layout = undefined;

fn fail(err: anyerror) u32 {
    last_error = @errorName(err);
    return 0;
}

fn input(ptr: usize, len: usize) []const u8 {
    if (len == 0) {
        return &.{};
    }
    const bytes: [*]const u8 = @ptrFromInt(ptr);
    return bytes[0..len];
}

fn deinitStaging() void {
    if (staging) |*next| {
        next.deinit();
        staging = null;
    }
}

export fn allocate(len: usize) usize {
    const bytes = allocator.alloc(u8, len) catch return 0;
    return @intFromPtr(bytes.ptr);
}

export fn freeAllocation(ptr: usize, len: usize) void {
    if (len == 0) {
        return;
    }
    const bytes: [*]u8 = @ptrFromInt(ptr);
    allocator.free(bytes[0..len]);
}

/// Starts an atomic replacement for the active table.
export fn beginBuild() u32 {
    deinitStaging();
    staging = Dictionary.init(allocator);
    last_error = "";
    return 1;
}

/// Adds one UTF-8 entry to the table currently being built.
export fn addEntry(key_ptr: usize, key_len: usize, value_ptr: usize, value_len: usize) u32 {
    const next = if (staging) |*value| value else {
        last_error = "NoBuildInProgress";
        return 0;
    };
    next.set(input(key_ptr, key_len), input(value_ptr, value_len)) catch |err| return fail(err);
    last_error = "";
    return 1;
}

/// Makes the completed staging table active without modifying it further.
export fn finishBuild() u32 {
    const next = if (staging) |*value| value else {
        last_error = "NoBuildInProgress";
        return 0;
    };
    if (next.image().len == 0) {
        last_error = "EmptyTable";
        return 0;
    }

    dictionary.deinit();
    dictionary = next.*;
    staging = null;
    lookup_result = &.{};
    lookup_flags = @intFromEnum(fullaz.sstable.EntryFlags.value);
    lookup_lsn = 0;
    last_error = "";
    return 1;
}

export fn cancelBuild() void {
    deinitStaging();
    last_error = "";
}

export fn reset() void {
    deinitStaging();
    dictionary.deinit();
    dictionary = Dictionary.init(allocator);
    lookup_result = &.{};
    lookup_flags = @intFromEnum(fullaz.sstable.EntryFlags.value);
    lookup_lsn = 0;
    last_error = "";
}

/// Builds a roughly one-megabyte SSTable in one writer pass for the file inspector.
export fn loadLargeSample() u32 {
    deinitStaging();
    const inputs = allocator.alloc(Dictionary.InputEntry, large_entry_count) catch |err| {
        return fail(err);
    };
    defer allocator.free(inputs);
    const source_bytes = allocator.alloc(
        u8,
        large_entry_count * (large_key_bytes + large_value_bytes),
    ) catch |err| {
        return fail(err);
    };
    defer allocator.free(source_bytes);

    var offset: usize = 0;
    for (inputs, 0..) |*input_entry, index| {
        const key_bytes = source_bytes[offset .. offset + large_key_bytes];
        offset += key_bytes.len;
        _ = std.fmt.bufPrint(key_bytes, "lexeme-{d:0>4}", .{index}) catch unreachable;

        const value_bytes = source_bytes[offset .. offset + large_value_bytes];
        offset += value_bytes.len;
        const prefix = std.fmt.bufPrint(
            value_bytes,
            "Generated lexicon definition {d}. ",
            .{index},
        ) catch unreachable;
        var filled = prefix.len;
        while (filled < value_bytes.len) {
            const fill_len = @min(value_bytes.len - filled, large_value_fill.len);
            @memcpy(value_bytes[filled .. filled + fill_len], large_value_fill[0..fill_len]);
            filled += fill_len;
        }
        input_entry.* = .{
            .key = key_bytes,
            .value = if (index % 17 == 0) "" else value_bytes,
            .flags = if (index % 17 == 0) .tombstone else .value,
            .lsn = @intCast(index + 1),
        };
    }

    var next = Dictionary.init(allocator);
    errdefer next.deinit();
    next.replaceAll(inputs) catch |err| {
        return fail(err);
    };
    dictionary.deinit();
    dictionary = next;
    lookup_result = &.{};
    lookup_flags = @intFromEnum(fullaz.sstable.EntryFlags.value);
    lookup_lsn = 0;
    last_error = "";
    return 1;
}

export fn lookup(key_ptr: usize, key_len: usize) u32 {
    var scratch = sstable.dictionary.ReadScratch{
        .data_page = &data_page,
        .key = &key,
    };
    const entry = dictionary.lookup(input(key_ptr, key_len), &scratch) catch |err| {
        return fail(err);
    } orelse {
        last_error = "NotFound";
        return 0;
    };
    lookup_result = entry.value;
    lookup_flags = @intFromEnum(entry.metadata.flags);
    lookup_lsn = entry.metadata.lsn;
    last_error = "";
    return 1;
}

export fn imagePtr() usize {
    return @intFromPtr(dictionary.image().ptr);
}

export fn imageLen() usize {
    return dictionary.image().len;
}

/// Copies layout metadata into stable WASM memory as consecutive usize words.
export fn snapshotLayout() u32 {
    layout_snapshot = dictionary.layout() orelse {
        last_error = "EmptyTable";
        return 0;
    };
    last_error = "";
    return 1;
}

export fn layoutPtr() usize {
    return @intFromPtr(&layout_snapshot);
}

export fn layoutWordCount() usize {
    return @sizeOf(Dictionary.Layout) / @sizeOf(usize);
}

export fn lookupResultPtr() usize {
    return @intFromPtr(lookup_result.ptr);
}

export fn lookupResultLen() usize {
    return lookup_result.len;
}

export fn lookupFlags() u8 {
    return lookup_flags;
}

export fn lookupLsn() u64 {
    return lookup_lsn;
}

export fn lastErrorPtr() usize {
    return @intFromPtr(last_error.ptr);
}

export fn lastErrorLen() usize {
    return last_error.len;
}

export fn maxEntries() usize {
    return sstable.dictionary.max_entries;
}

export fn largeEntryCount() usize {
    return large_entry_count;
}
