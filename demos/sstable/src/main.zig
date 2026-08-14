const std = @import("std");
const Io = std.Io;
const sstable = @import("sstable");

const Dictionary = sstable.dictionary.Dictionary;

const demo_entries = [_]struct { key: []const u8, value: []const u8 }{
    .{ .key = "ant", .value = "small, social, and strong" },
    .{ .key = "beetle", .value = "armoured insect" },
    .{ .key = "otter", .value = "playful river mammal" },
    .{ .key = "zebra", .value = "black and white stripes" },
};

fn printHex(out: *Io.Writer, bytes: []const u8) !void {
    for (bytes, 0..) |byte, index| {
        if (index % 16 == 0) {
            try out.print("\n  {x:0>4}: ", .{index});
        }
        try out.print("{x:0>2} ", .{byte});
    }
    try out.writeByte('\n');
}

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();
    const lookup_key = args.next();
    if (args.next() != null) {
        try out.writeAll("usage: sstable [key]\n");
        try out.flush();
        return;
    }

    var dictionary = Dictionary.init(init.gpa);
    defer dictionary.deinit();
    for (demo_entries) |entry| {
        try dictionary.set(entry.key, entry.value);
    }

    const layout = dictionary.layout().?;
    try out.print("fullaz / SSTable format explorer\n\n", .{});
    try out.print("entries: {d}\n", .{layout.entry_count});
    for (demo_entries) |entry| {
        try out.print("  {s:<8} {s}\n", .{ entry.key, entry.value });
    }
    try out.print(
        "\nphysical file: {d} bytes\n" ++
            "  data pages  offset {d:>5}  length {d:>5}  ({d} page, up to {d} B each)\n" ++
            "  bloom       offset {d:>5}  length {d:>5}  ({d} bits, {d} hashes)\n" ++
            "  B+tree index offset {d:>5}  length {d:>5}  ({d} key, {d} page, root {d})\n" ++
            "  footer      offset {d:>5}  length {d:>5}\n" ++
            "  trailer     offset {d:>5}  length {d:>5}\n",
        .{
            layout.file_bytes,
            layout.data_offset,
            layout.data_bytes,
            layout.data_page_count,
            layout.data_page_max_bytes,
            layout.bloom_offset,
            layout.bloom_bytes,
            layout.bloom_bit_count,
            layout.bloom_hash_count,
            layout.index_offset,
            layout.index_page_bytes * layout.index_page_count,
            layout.index_entry_count,
            layout.index_page_count,
            layout.index_root_page_id,
            layout.footer_offset,
            layout.footer_bytes,
            layout.footer_offset + layout.footer_bytes,
            layout.trailer_bytes,
        },
    );

    const image = dictionary.image();
    try out.writeAll("first 64 bytes:");
    try printHex(out, image[0..@min(image.len, 64)]);

    if (lookup_key) |key| {
        var data_page: [sstable.dictionary.settings.data_page_bytes]u8 = undefined;
        var scratch_key: [sstable.dictionary.max_key_bytes]u8 = undefined;
        var scratch = sstable.dictionary.ReadScratch{
            .data_page = &data_page,
            .key = &scratch_key,
        };
        const entry = try dictionary.lookup(key, &scratch);
        if (entry) |found| {
            try out.print(
                "lookup {s}: {s} ({s}, LSN {d})\n",
                .{ key, found.value, @tagName(found.metadata.flags), found.metadata.lsn },
            );
        } else {
            try out.print("lookup {s}: not found\n", .{key});
        }
    } else {
        try out.writeAll("pass a key to look it up, e.g. zig build run-sstable -- otter\n");
    }
    try out.flush();
}
