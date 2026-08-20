const std = @import("std");
const pages = @import("fullaz").pages;

fn TestTrait(comptime stable_name: []const u8, comptime roles: []const []const u8) type {
    return struct {
        pub const kind_name: []const u8 = stable_name;
        pub const format_version: u32 = 1;
        pub const page_kind_count: usize = roles.len;
        pub const page_roles: [page_kind_count][]const u8 = roles[0..page_kind_count].*;

        pub fn Binding(comptime BackendT: type) type {
            _ = BackendT;
            return struct {};
        }
    };
}

test "Pages: empty schema preserves its page ID type" {
    const Empty = pages.Schema(.{ .page_id = u32 });

    try std.testing.expect(Empty.PageId == u32);
    try std.testing.expectEqual(@as(usize, 0), Empty.fields.len);
}

test "Pages: schema add is immutable and assigns consecutive page kinds" {
    const FirstTrait = TestTrait("test.first", &.{ "leaf", "inode" });
    const SecondTrait = TestTrait("test.second", &.{"data"});
    const Empty = pages.Schema(.{ .page_id = u32 });
    const One = Empty.add("index", .{ .Trait = FirstTrait });
    const Two = One.add("jobs", .{ .Trait = SecondTrait });

    try std.testing.expectEqual(@as(usize, 0), Empty.fields.len);
    try std.testing.expectEqual(@as(usize, 1), One.fields.len);
    try std.testing.expectEqual(@as(usize, 2), Two.fields.len);
    try std.testing.expectEqualStrings("index", Two.fields[0].name);
    try std.testing.expectEqualStrings("jobs", Two.fields[1].name);
    try std.testing.expect(Two.fields[0].descriptor.Trait == FirstTrait);
    try std.testing.expect(Two.fields[1].descriptor.Trait == SecondTrait);
    try std.testing.expectEqual(
        pages.PageKindRange{ .base = 0x0100, .count = 2 },
        Two.fields[0].page_kinds,
    );
    try std.testing.expectEqual(
        pages.PageKindRange{ .base = 0x0102, .count = 1 },
        Two.fields[1].page_kinds,
    );
}
