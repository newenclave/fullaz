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

test "OrthTree packed view: node slots share a page and preserve node references" {
    const MutableView = fullaz.spatial.orthtree.models.paged.PackedView(u32, u16, i32, 2, TraitStorage, .little, false);
    const ReadView = fullaz.spatial.orthtree.models.paged.PackedView(u32, u16, i32, 2, TraitStorage, .little, true);
    const Box = MutableView.Box;
    const NodeId = fullaz.spatial.orthtree.models.paged.NodeId(u32, u16);
    const layout_id: u32 = 0x12345678;
    const trait = TraitStorage{ .bytes = .{ 1, 2, 3, 4 } };
    var page: [512]u8 = undefined;
    var view = MutableView.NodePage.init(&page);
    try view.formatPage(0x71, 7, layout_id);
    try view.validatePage(7, 0x71, layout_id);

    const first_slot = (try view.allocateSlot()).?;
    const second_slot = (try view.allocateSlot()).?;
    try std.testing.expect(first_slot != second_slot);
    {
        var node = try view.slotMut(first_slot);
        node.formatSlot(Box.create(.{ -10, 20 }, .{ 30, 40 }), &trait);
        node.setParent(.{ .page_id = 3, .slot_id = 2 });
        try node.setChild(0, .{ .page_id = 7, .slot_id = @intCast(second_slot) });
        node.setInternal();
        try node.validate();
    }
    {
        var node = try view.slotMut(second_slot);
        node.formatSlot(Box.create(.{ 0, 0 }, .{ 5, 5 }), &trait);
        try node.validate();
    }

    const read_page = ReadView.NodePage.init(&page);
    try read_page.validatePage(7, 0x71, layout_id);
    const read_node = try read_page.slot(first_slot);
    try read_node.validate();
    try std.testing.expect(std.meta.eql(Box.create(.{ -10, 20 }, .{ 30, 40 }), read_node.bounds()));
    try std.testing.expectEqual(NodeId{ .page_id = 3, .slot_id = 2 }, read_node.getParent().?);
    try std.testing.expectEqual(NodeId{ .page_id = 7, .slot_id = @intCast(second_slot) }, (try read_node.getChild(0)).?);
    try std.testing.expectEqualDeep(trait, read_node.trait().*);
}

test "OrthTree packed view: node page FSM location accessor round trips" {
    const MutableView = fullaz.spatial.orthtree.models.paged.PackedView(u32, u16, i32, 2, TraitStorage, .little, false);
    const LocationAccessor = fullaz.spatial.orthtree.models.paged.NodePageLocationAccessor(u32, u16, .little);
    var page: [512]u8 = undefined;
    var view = MutableView.NodePage.init(&page);
    try view.formatPage(0x71, 7, 0x12345678);

    try std.testing.expect((try LocationAccessor.read(&page)) == null);
    try LocationAccessor.write(&page, .{ .page_id = 11, .slot_id = 4 });
    try std.testing.expectEqual(LocationAccessor.Location{ .page_id = 11, .slot_id = 4 }, (try LocationAccessor.read(&page)).?);
    try LocationAccessor.clear(&page);
    try std.testing.expect((try LocationAccessor.read(&page)) == null);
}
