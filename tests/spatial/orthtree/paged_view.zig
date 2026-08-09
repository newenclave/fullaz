const std = @import("std");
const fullaz = @import("fullaz");

const TraitStorage = extern struct {
    bytes: [4]u8,
};

test "OrthTree paged trait: empty storage is deterministic" {
    const Trait = fullaz.spatial.orthtree.traits.PagedEmpty(i32, 2, []const u8);
    var storage: Trait.Storage = undefined;

    Trait.format(&storage);
    try std.testing.expect(Trait.validate(&storage));
    storage.reserved[0] = 1;
    try std.testing.expect(!Trait.validate(&storage));
}

test "OrthTree paged view: formats and validates structural node metadata" {
    const MutableView = fullaz.spatial.orthtree.models.paged.View(u32, u16, i32, 2, TraitStorage, .little, false);
    const ReadView = fullaz.spatial.orthtree.models.paged.View(u32, u16, i32, 2, TraitStorage, .little, true);
    const Box = MutableView.Node.Box;
    const node_bounds = Box.create(.{ -10, 20 }, .{ 30, 40 });
    const trait = TraitStorage{ .bytes = .{ 1, 2, 3, 4 } };
    var page: [512]u8 = undefined;
    var view = MutableView.Node.init(&page);

    view.formatPage(0x71, 7, node_bounds, &trait);
    try view.validatePage(7);
    try std.testing.expect(std.meta.eql(node_bounds, view.bounds()));
    try std.testing.expectEqualDeep(trait, view.trait().*);

    view.setParent(4);
    try view.setEntryChain(8, 9, 2);
    try view.setLevel(3);
    view.setInternal();
    try view.setChild(0, 10);

    const read_view = ReadView.Node.init(&page);
    try read_view.validatePage(7);
    try std.testing.expectEqual(@as(?u32, 4), read_view.getParent());
    try std.testing.expectEqual(@as(usize, 3), read_view.getLevel());
    try std.testing.expectEqual(@as(?u32, 10), try read_view.getChild(0));
    const chain = read_view.entryChain();
    try std.testing.expectEqual(@as(?u32, 8), chain.first);
    try std.testing.expectEqual(@as(?u32, 9), chain.last);
    try std.testing.expectEqual(@as(usize, 2), chain.count);
    try std.testing.expectError(error.BadData, read_view.validatePage(8));
}
