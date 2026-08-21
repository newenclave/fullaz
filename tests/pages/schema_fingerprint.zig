const std = @import("std");
const fullaz = @import("fullaz");

fn FingerprintTrait(comptime setting: u16) type {
    return struct {
        pub const kind_name: []const u8 = "test.fingerprint";
        pub const format_version: u32 = 1;
        pub const page_kind_count: usize = 1;
        pub const page_roles: [page_kind_count][]const u8 = .{"data"};

        pub fn fingerprint(writer: *fullaz.pages.FingerprintWriter) void {
            writer.writeInt(u16, setting);
        }

        pub fn Binding(comptime BackendT: type) type {
            _ = BackendT;
            return struct {};
        }
    };
}

test "Pages: schema fingerprint is deterministic and layout sensitive" {
    const U32 = fullaz.pages.Schema(.{ .page_id = u32 });
    const U64 = fullaz.pages.Schema(.{ .page_id = u64 });
    const first = fullaz.pages.schemaFingerprint(U32);
    const second = fullaz.pages.schemaFingerprint(U32);
    try std.testing.expectEqualSlices(u8, &first, &second);
    try std.testing.expect(!std.mem.eql(u8, &first, &fullaz.pages.schemaFingerprint(U64)));
}

test "Pages: schema fingerprint delegates component settings to traits" {
    const First = fullaz.pages.Schema(.{ .page_id = u32 })
        .add("component", .{ .Trait = FingerprintTrait(1) });
    const Second = fullaz.pages.Schema(.{ .page_id = u32 })
        .add("component", .{ .Trait = FingerprintTrait(2) });

    const first = fullaz.pages.schemaFingerprint(First);
    const second = fullaz.pages.schemaFingerprint(Second);
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
}
