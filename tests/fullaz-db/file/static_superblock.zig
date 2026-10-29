const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

test "fullaz-db: static superblock detects identity and CRC corruption" {
    const Metadata = extern struct { root: u32 };
    const Superblock = fullaz_db.StaticSuperblock(Metadata);
    const identity = Superblock.Identity{
        .image_id = @as([16]u8, @splat(1)),
        .schema_digest = @as([32]u8, @splat(2)),
    };
    var page = @as([512]u8, @splat(0));
    try Superblock.format(&page, page.len, 7, identity, .{ .root = 4 }, true);
    const storage = try Superblock.read(&page, page.len, identity);
    try std.testing.expectEqual(@as(u16, 3), Superblock.version);
    try std.testing.expectEqual(@as(u16, 3), storage.version.get());
    try std.testing.expectEqual(@as(u64, 7), storage.page_count.get());
    try std.testing.expectEqual(@as(u32, 4), storage.metadata.root);

    var wrong_identity = identity;
    wrong_identity.image_id[0] ^= 1;
    try std.testing.expectError(error.IdentityMismatch, Superblock.read(&page, page.len, wrong_identity));

    page[0] ^= 1;
    try std.testing.expectError(error.BadSuperblock, Superblock.read(&page, page.len, identity));
}
