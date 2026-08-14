const std = @import("std");
const packed_int = @import("../core/packed_int.zig");

pub const interfaces = @import("interfaces.zig");

pub const Footer = @import("footer.zig").Footer;
pub const DataPage = @import("data_page.zig").DataPage;

pub const IndexBackend = enum {
    file,
    memory,
};

pub const EntryFlags = enum(u8) {
    value = 0,
    tombstone = 1,
};

pub const Settings = struct {
    max_entries_per_coded_block: usize = 16,
    max_coded_block_bytes: usize = 128 * 1024,
    data_page_bytes: usize = 500 * 1024,
    index_page_bytes: usize = 16 * 1024,
    max_key_bytes: usize = 4 * 1024,
    max_value_bytes: usize = 128 * 1024,
    bloom_false_positive_rate: f64 = 0.01,
};

pub const BuildOptions = struct {
    entry_count: usize,
    enforce_entry_count: bool = true,
    comparator_id: u32,
    settings: Settings = .{},
};

pub const OpenOptions = struct {
    comparator_id: u32,
    index_backend: IndexBackend = .file,
};

pub fn SstableFormat(
    comptime OffsetT: type,
    comptime PageIdT: type,
    comptime DataIndexT: type,
    comptime endian: std.builtin.Endian,
) type {
    return SstableFormatWithLsn(OffsetT, PageIdT, DataIndexT, u64, endian);
}

pub fn SstableFormatWithLsn(
    comptime OffsetT: type,
    comptime PageIdT: type,
    comptime DataIndexT: type,
    comptime LsnT: type,
    comptime endian: std.builtin.Endian,
) type {
    comptime {
        interfaces.assertUnsignedInt(OffsetT, "OffsetT");
        interfaces.assertUnsignedInt(PageIdT, "PageIdT");
        interfaces.assertUnsignedInt(DataIndexT, "DataIndexT");
        interfaces.assertUnsignedInt(LsnT, "LsnT");
    }

    return struct {
        pub const Offset = OffsetT;
        pub const PageId = PageIdT;
        pub const DataIndex = DataIndexT;
        pub const Lsn = LsnT;
        pub const Endian = endian;
    };
}

pub fn EntryMetadata(comptime Format: type) type {
    const PackedLsn = packed_int.PackedInt(Format.Lsn, Format.Endian);

    return struct {
        const Self = @This();

        pub const byte_len = 1 + @sizeOf(PackedLsn);
        pub const Error = error{InvalidMetadata};

        flags: EntryFlags,
        lsn: Format.Lsn,

        pub fn toBytes(self: Self) [byte_len]u8 {
            var bytes: [byte_len]u8 = undefined;
            bytes[0] = @intFromEnum(self.flags);
            const packed_lsn = PackedLsn.init(self.lsn);
            @memcpy(bytes[1..], &packed_lsn.bytes);
            return bytes;
        }

        pub fn fromBytes(bytes: []const u8) Error!Self {
            if (bytes.len != byte_len) {
                return Error.InvalidMetadata;
            }
            const flags = switch (bytes[0]) {
                @intFromEnum(EntryFlags.value) => EntryFlags.value,
                @intFromEnum(EntryFlags.tombstone) => EntryFlags.tombstone,
                else => return Error.InvalidMetadata,
            };
            const packed_lsn = PackedLsn.fromSlice(bytes[1..]) catch {
                return Error.InvalidMetadata;
            };
            return .{
                .flags = flags,
                .lsn = packed_lsn.get(),
            };
        }
    };
}

pub const Writer = @import("writer.zig").Writer;
pub const Reader = @import("reader.zig").Reader;
pub const Merger = @import("merge.zig").Merger;
