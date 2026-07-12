const std = @import("std");
const path = @import("fsx").path;

test "path Posix.split: tokenizes and skips empty components" {
    const P = path.Default;
    var comps: [P.MaxDepth][]const u8 = undefined;

    try std.testing.expectEqual(@as(usize, 0), try P.split("/", &comps));
    try std.testing.expectEqual(@as(usize, 0), try P.split("", &comps));

    {
        const n = try P.split("/a/b/c", &comps);
        try std.testing.expectEqual(@as(usize, 3), n);
        try std.testing.expectEqualStrings("a", comps[0]);
        try std.testing.expectEqualStrings("b", comps[1]);
        try std.testing.expectEqualStrings("c", comps[2]);
    }
    {
        const n = try P.split("//a///b/", &comps);
        try std.testing.expectEqual(@as(usize, 2), n);
        try std.testing.expectEqualStrings("a", comps[0]);
        try std.testing.expectEqualStrings("b", comps[1]);
    }
}

test "path Posix.split: PathTooDeep past MaxDepth" {
    const P = path.Posix(2);
    var comps: [P.MaxDepth][]const u8 = undefined;

    try std.testing.expectEqual(@as(usize, 2), try P.split("/a/b", &comps));
    try std.testing.expectError(P.Error.PathTooDeep, P.split("/a/b/c", &comps));
}
