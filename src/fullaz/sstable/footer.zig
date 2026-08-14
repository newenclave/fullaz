const std = @import("std");
const PackedFloat = @import("../core/packed_int.zig").PackedFloat;
const PackedInt = @import("../core/packed_int.zig").PackedInt;
const sstable = @import("sstable.zig");

pub fn Footer(comptime Format: type) type {
    const PackedOffset = PackedInt(Format.Offset, Format.Endian);
    const PackedPageId = PackedInt(Format.PageId, Format.Endian);
    const PackedDataIndex = PackedInt(Format.DataIndex, Format.Endian);
    const PackedU16 = PackedInt(u16, Format.Endian);
    const PackedU32 = PackedInt(u32, Format.Endian);
    const PackedF64 = PackedFloat(f64, Format.Endian);

    const magic: u32 = 0x5353_5446;
    const version: u16 = 2;
    const entry_metadata_bytes = 1 + @sizeOf(Format.Lsn);

    const HeaderImpl = extern struct {
        magic: PackedU32,
        version: PackedU16,
        header_size: PackedU16,
        footer_size: PackedDataIndex,
        checksum: PackedU32,
        comparator_id: PackedU32,
        entry_count: PackedOffset,
        data_offset: PackedOffset,
        data_length: PackedOffset,
        data_page_count: PackedDataIndex,
        bloom_offset: PackedOffset,
        bloom_length: PackedOffset,
        bloom_bit_count: PackedOffset,
        bloom_hash_count: PackedU32,
        index_offset: PackedOffset,
        index_page_size: PackedDataIndex,
        index_page_count: PackedPageId,
        index_root_page_id: PackedPageId,
        max_entries_per_coded_block: PackedDataIndex,
        max_coded_block_bytes: PackedDataIndex,
        data_page_bytes: PackedDataIndex,
        max_key_bytes: PackedDataIndex,
        max_value_bytes: PackedDataIndex,
        entry_metadata_bytes: PackedU16,
        bloom_false_positive_rate: PackedF64,
    };

    const TrailerImpl = extern struct {
        magic: PackedU32,
        version: PackedU16,
        trailer_size: PackedU16,
        footer_size: PackedDataIndex,
        checksum: PackedU32,
    };

    return struct {
        const Self = @This();

        pub const Header = HeaderImpl;
        pub const Trailer = TrailerImpl;
        pub const Error = error{
            BufferTooSmall,
            BadMagic,
            BadVersion,
            BadHeaderSize,
            BadFooterSize,
            BadChecksum,
            BadSettings,
            BadRegion,
            BadTrailer,
        };

        pub fn formatTrailer(bytes: []u8, footer_size: usize) Error!void {
            if (bytes.len != @sizeOf(Trailer)) {
                return Error.BadTrailer;
            }
            const packed_footer_size = std.math.cast(
                Format.DataIndex,
                footer_size,
            ) orelse return Error.BadTrailer;
            @memset(bytes, 0);
            const trailer: *Trailer = @ptrCast(bytes.ptr);
            trailer.magic.set(magic);
            trailer.version.set(version);
            trailer.trailer_size.set(@intCast(bytes.len));
            trailer.footer_size.set(packed_footer_size);
            trailer.checksum.set(0);
            trailer.checksum.set(trailerChecksum(bytes));
        }

        pub fn validateTrailer(bytes: []const u8) Error!usize {
            if (bytes.len != @sizeOf(Trailer)) {
                return Error.BadTrailer;
            }
            const trailer: *const Trailer = @ptrCast(bytes.ptr);
            if (trailer.magic.get() != magic or
                trailer.version.get() != version or
                trailer.trailer_size.get() != bytes.len or
                trailer.checksum.get() != trailerChecksum(bytes))
            {
                return Error.BadTrailer;
            }
            return std.math.cast(usize, trailer.footer_size.get()) orelse Error.BadTrailer;
        }

        pub const Info = struct {
            comparator_id: u32,
            entry_count: Format.Offset,
            data_offset: Format.Offset,
            data_length: Format.Offset,
            data_page_count: Format.DataIndex,
            bloom_offset: Format.Offset,
            bloom_length: Format.Offset,
            bloom_bit_count: Format.Offset,
            bloom_hash_count: u32,
            index_offset: Format.Offset,
            index_page_size: Format.DataIndex,
            index_page_count: Format.PageId,
            index_root_page_id: Format.PageId,
            entry_metadata_bytes: usize = entry_metadata_bytes,
            settings: sstable.Settings,
        };

        pub fn View(comptime read_only: bool) type {
            return struct {
                const ViewSelf = @This();
                const Bytes = if (read_only) []const u8 else []u8;

                bytes: Bytes,

                pub fn init(bytes: Bytes) Error!ViewSelf {
                    if (bytes.len < @sizeOf(Header)) {
                        return Error.BufferTooSmall;
                    }
                    return .{ .bytes = bytes };
                }

                pub fn header(self: *const ViewSelf) *const Header {
                    return @ptrCast(self.bytes.ptr);
                }

                pub fn headerMut(self: *ViewSelf) *Header {
                    if (read_only) {
                        @compileError("cannot mutate a read-only SSTable footer view");
                    }
                    return @ptrCast(self.bytes.ptr);
                }

                pub fn format(self: *ViewSelf, footer_info: Info) Error!void {
                    if (read_only) {
                        @compileError("cannot format a read-only SSTable footer view");
                    }
                    try validateInfo(footer_info, self.bytes.len);

                    @memset(self.bytes, 0);
                    const hdr = self.headerMut();
                    hdr.magic.set(magic);
                    hdr.version.set(version);
                    hdr.header_size.set(@intCast(@sizeOf(Header)));
                    hdr.footer_size.set(@intCast(self.bytes.len));
                    hdr.checksum.set(0);
                    hdr.comparator_id.set(footer_info.comparator_id);
                    hdr.entry_count.set(footer_info.entry_count);
                    hdr.data_offset.set(footer_info.data_offset);
                    hdr.data_length.set(footer_info.data_length);
                    hdr.data_page_count.set(footer_info.data_page_count);
                    hdr.bloom_offset.set(footer_info.bloom_offset);
                    hdr.bloom_length.set(footer_info.bloom_length);
                    hdr.bloom_bit_count.set(footer_info.bloom_bit_count);
                    hdr.bloom_hash_count.set(footer_info.bloom_hash_count);
                    hdr.index_offset.set(footer_info.index_offset);
                    hdr.index_page_size.set(footer_info.index_page_size);
                    hdr.index_page_count.set(footer_info.index_page_count);
                    hdr.index_root_page_id.set(footer_info.index_root_page_id);
                    hdr.max_entries_per_coded_block.set(
                        @intCast(footer_info.settings.max_entries_per_coded_block),
                    );
                    hdr.max_coded_block_bytes.set(
                        @intCast(footer_info.settings.max_coded_block_bytes),
                    );
                    hdr.data_page_bytes.set(@intCast(footer_info.settings.data_page_bytes));
                    hdr.max_key_bytes.set(@intCast(footer_info.settings.max_key_bytes));
                    hdr.max_value_bytes.set(@intCast(footer_info.settings.max_value_bytes));
                    hdr.entry_metadata_bytes.set(@intCast(footer_info.entry_metadata_bytes));
                    hdr.bloom_false_positive_rate.set(footer_info.settings.bloom_false_positive_rate);
                    hdr.checksum.set(checksum(self.bytes));
                }

                pub fn validate(self: *const ViewSelf, footer_offset: Format.Offset) Error!Info {
                    const hdr = self.header();
                    if (hdr.magic.get() != magic) {
                        return Error.BadMagic;
                    }
                    if (hdr.version.get() != version) {
                        return Error.BadVersion;
                    }
                    if (hdr.header_size.get() != @sizeOf(Header)) {
                        return Error.BadHeaderSize;
                    }
                    if (hdr.footer_size.get() != self.bytes.len) {
                        return Error.BadFooterSize;
                    }
                    if (hdr.checksum.get() != checksum(self.bytes)) {
                        return Error.BadChecksum;
                    }

                    const footer_info = try self.info();
                    try validateInfo(footer_info, self.bytes.len);
                    try validateRegions(footer_info, footer_offset);
                    return footer_info;
                }

                pub fn info(self: *const ViewSelf) Error!Info {
                    const hdr = self.header();
                    return .{
                        .comparator_id = hdr.comparator_id.get(),
                        .entry_count = hdr.entry_count.get(),
                        .data_offset = hdr.data_offset.get(),
                        .data_length = hdr.data_length.get(),
                        .data_page_count = hdr.data_page_count.get(),
                        .bloom_offset = hdr.bloom_offset.get(),
                        .bloom_length = hdr.bloom_length.get(),
                        .bloom_bit_count = hdr.bloom_bit_count.get(),
                        .bloom_hash_count = hdr.bloom_hash_count.get(),
                        .index_offset = hdr.index_offset.get(),
                        .index_page_size = hdr.index_page_size.get(),
                        .index_page_count = hdr.index_page_count.get(),
                        .index_root_page_id = hdr.index_root_page_id.get(),
                        .entry_metadata_bytes = hdr.entry_metadata_bytes.get(),
                        .settings = .{
                            .max_entries_per_coded_block = try toUsize(
                                hdr.max_entries_per_coded_block.get(),
                            ),
                            .max_coded_block_bytes = try toUsize(
                                hdr.max_coded_block_bytes.get(),
                            ),
                            .data_page_bytes = try toUsize(hdr.data_page_bytes.get()),
                            .index_page_bytes = try toUsize(hdr.index_page_size.get()),
                            .max_key_bytes = try toUsize(hdr.max_key_bytes.get()),
                            .max_value_bytes = try toUsize(hdr.max_value_bytes.get()),
                            .bloom_false_positive_rate = hdr.bloom_false_positive_rate.get(),
                        },
                    };
                }

                fn checksum(bytes: []const u8) u32 {
                    const checksum_offset = @offsetOf(Header, "checksum");
                    var crc = std.hash.Crc32.init();
                    crc.update(bytes[0..checksum_offset]);
                    crc.update(bytes[checksum_offset + @sizeOf(PackedU32) ..]);
                    return crc.final();
                }
            };
        }

        fn validateInfo(info: Info, footer_size: usize) Error!void {
            if (footer_size < @sizeOf(Header)) {
                return Error.BufferTooSmall;
            }
            if (info.index_page_size != footer_size) {
                return Error.BadFooterSize;
            }
            if (info.settings.index_page_bytes != footer_size) {
                return Error.BadSettings;
            }
            if (info.entry_metadata_bytes != entry_metadata_bytes) {
                return Error.BadSettings;
            }
            if (info.settings.max_entries_per_coded_block == 0 or
                info.settings.max_coded_block_bytes == 0 or
                info.settings.data_page_bytes == 0 or
                info.settings.max_key_bytes == 0 or
                info.settings.max_value_bytes == 0 or
                !(info.settings.bloom_false_positive_rate > 0 and
                    info.settings.bloom_false_positive_rate < 1))
            {
                return Error.BadSettings;
            }
            if (info.index_page_count == 0 or
                info.index_root_page_id >= info.index_page_count)
            {
                return Error.BadRegion;
            }
        }

        fn validateRegions(info: Info, footer_offset: Format.Offset) Error!void {
            const data_end = try endOf(info.data_offset, info.data_length);
            if (data_end > info.bloom_offset) {
                return Error.BadRegion;
            }
            const bloom_end = try endOf(info.bloom_offset, info.bloom_length);
            if (bloom_end > info.index_offset) {
                return Error.BadRegion;
            }
            const index_page_size = std.math.cast(
                Format.Offset,
                info.index_page_size,
            ) orelse return Error.BadRegion;
            const index_length = std.math.mul(Format.Offset, index_page_size, info.index_page_count) catch {
                return Error.BadRegion;
            };
            if (try endOf(info.index_offset, index_length) != footer_offset) {
                return Error.BadRegion;
            }
        }

        fn endOf(offset: Format.Offset, length: Format.Offset) Error!Format.Offset {
            const sum = @addWithOverflow(offset, length);
            if (sum[1] != 0) {
                return Error.BadRegion;
            }
            return sum[0];
        }

        fn toUsize(value: anytype) Error!usize {
            return std.math.cast(usize, value) orelse Error.BadSettings;
        }

        fn trailerChecksum(bytes: []const u8) u32 {
            const checksum_offset = @offsetOf(Trailer, "checksum");
            var crc = std.hash.Crc32.init();
            crc.update(bytes[0..checksum_offset]);
            crc.update(bytes[checksum_offset + @sizeOf(PackedU32) ..]);
            return crc.final();
        }
    };
}
