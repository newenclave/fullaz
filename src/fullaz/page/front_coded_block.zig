const std = @import("std");
const PackedInt = @import("../core/packed_int.zig").PackedInt;

pub fn FrontCodedBlock(
    comptime CountT: type,
    comptime IndexT: type,
    comptime BlockSizeT: type,
    comptime endian: std.builtin.Endian,
) type {
    const Count = PackedInt(CountT, endian);
    const Index = PackedInt(IndexT, endian);
    const BlockSize = PackedInt(BlockSizeT, endian);

    const HeaderImpl = extern struct {
        const Self = @This();
        entry_count: Count,
        used_bytes: BlockSize,
        max_key_len: Index,
        pub fn format(self: *Self) void {
            self.entry_count.setMin();
            self.used_bytes.setMin();
            self.max_key_len.setMin();
        }
    };

    const EntryHeaderImpl = extern struct {
        const Self = @This();
        shared_len: Index,
        suffix_len: Index,
        value_len: Index,
        pub fn format(self: *Self) void {
            self.shared_len.setMin();
            self.suffix_len.setMin();
            self.value_len.setMin();
        }
    };

    return struct {
        pub const Header = HeaderImpl;
        pub const EntryHeader = EntryHeaderImpl;
    };
}
