const std = @import("std");
const constants = @import("fsx").constants;

test "fsx constants: sane values, distinct page kinds" {
    try std.testing.expect(constants.magic != 0);
    try std.testing.expect(constants.version >= 1);
    try std.testing.expectEqual(@as(constants.PageId, 0), constants.superblock_pid);
    try std.testing.expect(constants.default_block_size >= 64);

    const K = constants.PageKind;
    const roles = [_]u16{
        K.superblock, K.inode,           K.dir_leaf,         K.dir_inode,
        K.file_chunk, K.file_index_leaf, K.file_index_inode,
    };
    for (roles, 0..) |a, i| {
        try std.testing.expect(a != K.freed);
        for (roles[i + 1 ..]) |b| {
            try std.testing.expect(a != b);
        }
    }
}
