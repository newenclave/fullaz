const std = @import("std");
const fullaz = @import("fullaz");

test "Pages: schema fingerprint is deterministic and layout sensitive" {
    const U32 = fullaz.pages.Schema(.{ .page_id = u32 });
    const U64 = fullaz.pages.Schema(.{ .page_id = u64 });
    const first = fullaz.pages.schemaFingerprint(U32);
    const second = fullaz.pages.schemaFingerprint(U32);
    try std.testing.expectEqualSlices(u8, &first, &second);
    try std.testing.expect(!std.mem.eql(u8, &first, &fullaz.pages.schemaFingerprint(U64)));
}
