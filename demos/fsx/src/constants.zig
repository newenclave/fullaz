const std = @import("std");

pub const endian: std.builtin.Endian = .little;

pub const PageId = u32;
pub const Size = u32;

pub const magic: u32 = 0x31585346; // "FSX1" in little-endian
pub const legacy_version: u16 = 1;
pub const version: u16 = 2;

pub const default_block_size: usize = 4096;

pub const superblock_pid: PageId = 0;

pub const pid_none: PageId = std.math.maxInt(PageId);

pub const max_name_len: usize = 64;
pub const dir_value_max: usize = 32;

pub const PageKind = struct {
    pub const superblock: u16 = 0x01;
    pub const inode: u16 = 0x02;
    pub const dir_leaf: u16 = 0x10;
    pub const dir_inode: u16 = 0x11;
    pub const file_chunk: u16 = 0x20;
    pub const file_index_leaf: u16 = 0x30;
    pub const file_index_inode: u16 = 0x31;
    pub const freed: u16 = std.math.maxInt(u16);
};

pub fn isSupportedVersion(format_version: u16) bool {
    return format_version == legacy_version or format_version == version;
}

pub fn fileIndexLeafKind(format_version: u16) u16 {
    return if (format_version == legacy_version) 0 else PageKind.file_index_leaf;
}

pub fn fileIndexInodeKind(format_version: u16) u16 {
    return if (format_version == legacy_version) 1 else PageKind.file_index_inode;
}
