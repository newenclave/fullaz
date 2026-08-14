const std = @import("std");

pub const interfaces = @import("interfaces.zig");
pub const Footer = @import("footer.zig").Footer;
pub const DataPage = @import("data_page.zig").DataPage;

pub const IndexBackend = enum {
    file,
    memory,
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
    comptime {
        interfaces.assertUnsignedInt(OffsetT, "OffsetT");
        interfaces.assertUnsignedInt(PageIdT, "PageIdT");
        interfaces.assertUnsignedInt(DataIndexT, "DataIndexT");
    }

    return struct {
        pub const Offset = OffsetT;
        pub const PageId = PageIdT;
        pub const DataIndex = DataIndexT;
        pub const Endian = endian;
    };
}
