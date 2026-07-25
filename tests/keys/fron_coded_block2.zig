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
const BlockREader = keys.memory_block.MemoryBlockView(u8);

const FrontCodedBlock = keys.front_coded_block2.FrontCodedBlock2(
    u8,
    u16,
    u32,
    BlockWriter,
    BlockREader,
    std.builtin.Endian.little,
    StrCmp.cmp,
    void,
);

const HEADER_SIZE = @sizeOf(FrontCodedBlock.Header);
const ENTRY_HEADER_SIZE = @sizeOf(FrontCodedBlock.EntryHeader);

// comptime CountT: type,
// comptime IndexT: type,
// comptime BlockSizeT: type,
// comptime BlockWriterT: type,
// comptime BlockViewT: type,
// comptime endian: std.builtin.Endian,
// comptime cmp: anytype,
// comptime Ctx: type,

test "Keys: Writer block paged" {
    var buf = [_]u8{0} ** 1024;
    var writer = BlockWriter.init(buf[0..]);
    defer writer.deinit();

    var scratch: [256]u8 = undefined;
    var builder = try FrontCodedBlock.Builder.init(writer, scratch[0..]);
    defer builder.deinit();

    std.debug.print("Expected len: {}...", .{builder.sizeAfterAdd("filesystem", "filesystem")});
    try builder.add("filesystem", "filesystem");
    std.debug.print("real len: {}\n", .{builder.block_writer.used().len});

    std.debug.print("Expected len: {}...", .{builder.sizeAfterAdd("filesystem_cache", "filesystem_cache")});
    try builder.add("filesystem_cache", "filesystem_cache");
    std.debug.print("real len: {}\n", .{builder.block_writer.used().len});

    std.debug.print("Expected len: {}...", .{builder.sizeAfterAdd("filesystem_cache_entry", "filesystem_cache_entry")});
    try builder.add("filesystem_cache_entry", "filesystem_cache_entry");
    std.debug.print("real len: {}\n", .{builder.block_writer.used().len});

    std.debug.print("Expected len: {}...", .{builder.sizeAfterAdd("filesystem_cache_entry_low", "filesystem_cache_entry_low")});
    try builder.add("filesystem_cache_entry_low", "filesystem_cache_entry_low");
    std.debug.print("real len: {}\n", .{builder.block_writer.used().len});

    var reader = try builder.reader();
    defer reader.deinit();

    std.debug.print("total bytes written: {}\n", .{builder.block_writer.used().len});

    // try std.testing.expectEqual(@as(usize, 3), reader.entryCount());
    // try std.testing.expectEqual(
    //     @as(usize, 25 + HEADER_SIZE + ENTRY_HEADER_SIZE),
    //     reader.usedBytes(),
    // );
    //try std.testing.expectEqual(@as(usize, 10), reader.maxKeyLen());

    var itr = try reader.iterator(scratch[0..]);
    defer itr.deinit();

    while (!itr.done()) {
        const key = itr.scratchKey();
        const value = try itr.value();
        std.debug.print("itr key: '{s}'', value: '{s}'\n", .{ key, value });
        try itr.next();
    }
}
