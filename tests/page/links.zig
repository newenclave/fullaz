const std = @import("std");
const Trait = @import("fullaz").page.links.Trait(u32, .little);

test "page links trait stores independent nullable page links" {
    var storage: Trait.Storage = undefined;
    Trait.format(&storage);

    try std.testing.expectEqual(@as(usize, 1), @alignOf(Trait.Storage));
    try std.testing.expect(Trait.validate(&storage));
    try std.testing.expectEqual(@as(?u32, null), Trait.getPrev(&storage));
    try std.testing.expectEqual(@as(?u32, null), Trait.getNext(&storage));

    Trait.setPrev(&storage, 11);
    try std.testing.expectEqual(@as(?u32, 11), Trait.getPrev(&storage));
    try std.testing.expectEqual(@as(?u32, null), Trait.getNext(&storage));

    Trait.setNext(&storage, 22);
    try std.testing.expectEqual(@as(?u32, 11), Trait.getPrev(&storage));
    try std.testing.expectEqual(@as(?u32, 22), Trait.getNext(&storage));

    Trait.setPrev(&storage, null);
    Trait.setNext(&storage, null);
    try std.testing.expectEqual(@as(?u32, null), Trait.getPrev(&storage));
    try std.testing.expectEqual(@as(?u32, null), Trait.getNext(&storage));
}
