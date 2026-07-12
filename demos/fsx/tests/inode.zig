const std = @import("std");
const fsx = @import("fsx");
const inode = fsx.inode;
const constants = fsx.constants;

const PageId = constants.PageId;

test "inode value: file record round-trips through the bpt value bytes" {
    var buf: [64]u8 = undefined;

    const node = inode.Inode{ .file = .{
        .first = 5,
        .last = 9,
        .total = 1234,
        .index = 12,
    } };
    const bytes = try inode.encode(node, &buf);
    try std.testing.expectEqual(inode.file_len, bytes.len);
    try std.testing.expectEqual(inode.Kind.file, try inode.kindOf(bytes));

    const got = try inode.decode(bytes);
    try std.testing.expectEqual(inode.Kind.file, @as(inode.Kind, got));
    try std.testing.expectEqual(@as(?PageId, 5), got.file.first);
    try std.testing.expectEqual(@as(?PageId, 9), got.file.last);
    try std.testing.expectEqual(@as(u32, 1234), got.file.total);
    try std.testing.expectEqual(@as(?PageId, 12), got.file.index);
}

test "inode value: fresh dir/file are empty; dir carries only its root" {
    var buf: [64]u8 = undefined;

    // Empty file: all roots null, size 0.
    {
        const bytes = try inode.encode(inode.Inode.newFile(), &buf);
        const got = try inode.decode(bytes);
        try std.testing.expect(got.file.first == null);
        try std.testing.expect(got.file.last == null);
        try std.testing.expect(got.file.index == null);
        try std.testing.expectEqual(@as(u32, 0), got.file.total);
    }
    // Dir value is minimal: just the (initially empty) bpt root.
    {
        const bytes = try inode.encode(inode.Inode.newDir(), &buf);
        try std.testing.expectEqual(inode.dir_len, bytes.len);
        try std.testing.expect(bytes.len < inode.file_len); // dir is smaller
        const got = try inode.decode(bytes);
        try std.testing.expect(got.dir.root == null);
    }
    // A dir with a real root round-trips.
    {
        const bytes = try inode.encode(.{ .dir = .{ .root = 77 } }, &buf);
        const got = try inode.decode(bytes);
        try std.testing.expectEqual(@as(?PageId, 77), got.dir.root);
    }
}

test "inode value: decode rejects bad kind / short buffer" {
    var buf: [64]u8 = undefined;
    const bytes = try inode.encode(inode.Inode.newDir(), &buf);

    buf[0] = 0xEE;
    try std.testing.expectError(inode.Error.BadKind, inode.decode(bytes));

    try std.testing.expectError(inode.Error.ShortBuffer, inode.kindOf(buf[0..0]));
    var tiny: [3]u8 = undefined;
    try std.testing.expectError(inode.Error.ShortBuffer, inode.encode(inode.Inode.newFile(), &tiny));
}
