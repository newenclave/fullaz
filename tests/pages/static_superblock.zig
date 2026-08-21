const std = @import("std");
const fullaz = @import("fullaz");

test "Pages: static superblock detects identity and CRC corruption" {
    const Metadata = extern struct { root: u32 };
    const Superblock = fullaz.pages.StaticSuperblock(Metadata);
    const identity = Superblock.Identity{
        .image_id = [_]u8{1} ** 16,
        .schema_digest = [_]u8{2} ** 32,
    };
    var page = [_]u8{0} ** 512;
    try Superblock.format(&page, page.len, 7, identity, .{ .root = 4 }, true);
    const storage = try Superblock.read(&page, page.len, identity);
    try std.testing.expectEqual(@as(u64, 7), storage.page_count.get());
    try std.testing.expectEqual(@as(u32, 4), storage.metadata.root);

    var wrong_identity = identity;
    wrong_identity.image_id[0] ^= 1;
    try std.testing.expectError(error.IdentityMismatch, Superblock.read(&page, page.len, wrong_identity));

    page[0] ^= 1;
    try std.testing.expectError(error.BadSuperblock, Superblock.read(&page, page.len, identity));
}
