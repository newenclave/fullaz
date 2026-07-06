const std = @import("std");
const fsx = @import("fsx");
const superblock = fsx.superblock;
const constants = fsx.constants;

const PageId = constants.PageId;

test "superblock: format is a fresh image, roots round-trip" {
    var page: [128]u8 = undefined;
    // Pre-dirty the buffer so we prove format zeroes + writes deterministically.
    @memset(&page, 0xAA);

    const SbMut = superblock.View(false);
    var sb = SbMut.init(&page);
    sb.format(4096);

    try sb.validate(4096);
    // A fresh image: empty root directory and empty free list.
    try std.testing.expect(sb.getRootDirRoot() == null);
    try std.testing.expect(sb.getFreedHead() == null);

    // Set the two roots; read back through a const view over the same bytes.
    sb.setRootDirRoot(7);
    sb.setFreedHead(99);
    const rd = superblock.View(true).init(&page);
    try rd.validate(4096);
    try std.testing.expectEqual(@as(?PageId, 7), rd.getRootDirRoot());
    try std.testing.expectEqual(@as(?PageId, 99), rd.getFreedHead());

    // Clearing maps back to null.
    sb.setRootDirRoot(null);
    try std.testing.expect(sb.getRootDirRoot() == null);
}

test "superblock: validate rejects bad magic / version / block size" {
    var page: [128]u8 = undefined;
    const SbMut = superblock.View(false);
    var sb = SbMut.init(&page);

    sb.format(4096);
    try std.testing.expectError(superblock.Error.BadBlockSize, sb.validate(8192));

    sb.format(4096);
    sb.headerMut().version.set(constants.version + 1);
    try std.testing.expectError(superblock.Error.BadVersion, sb.validate(4096));

    sb.format(4096);
    sb.headerMut().magic.set(0);
    try std.testing.expectError(superblock.Error.BadMagic, sb.validate(4096));
}
