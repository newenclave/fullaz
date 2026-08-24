const std = @import("std");
const fullaz = @import("fullaz");
const fullaz_db = @import("fullaz-db");

fn FingerprintTrait(comptime setting: u16) type {
    return struct {
        pub const kind_name: []const u8 = "test.fingerprint";
        pub const format_version: u32 = 1;
        pub const page_kind_count: usize = 1;
        pub const page_roles: [page_kind_count][]const u8 = .{"data"};

        pub fn fingerprint(writer: *fullaz_db.FingerprintWriter) void {
            writer.writeInt(u16, setting);
        }

        pub fn Binding(comptime BackendT: type) type {
            _ = BackendT;
            return struct {};
        }
    };
}

test "fullaz-db: schema fingerprint is deterministic and layout sensitive" {
    const U32 = fullaz_db.Schema(.{ .page_id = u32 });
    const U64 = fullaz_db.Schema(.{ .page_id = u64 });
    const first = fullaz_db.schemaFingerprint(U32);
    const second = fullaz_db.schemaFingerprint(U32);
    try std.testing.expectEqualSlices(u8, &first, &second);
    try std.testing.expect(!std.mem.eql(u8, &first, &fullaz_db.schemaFingerprint(U64)));
}

test "fullaz-db: schema fingerprint delegates component settings to traits" {
    const First = fullaz_db.Schema(.{ .page_id = u32 })
        .add("component", .{ .Trait = FingerprintTrait(1) });
    const Second = fullaz_db.Schema(.{ .page_id = u32 })
        .add("component", .{ .Trait = FingerprintTrait(2) });

    const first = fullaz_db.schemaFingerprint(First);
    const second = fullaz_db.schemaFingerprint(Second);
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
}
