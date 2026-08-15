const std = @import("std");
const Trait = @import("fullaz").storage.fsm.location.Trait(u32, u16, .little);

test "FSM location trait formats, stores, and clears a page slot reference" {
    var storage: Trait.Storage = undefined;
    Trait.format(&storage);

    try std.testing.expectEqual(@as(usize, 1), @alignOf(Trait.Storage));
    try std.testing.expect(Trait.validate(&storage));
    try std.testing.expectEqual(@as(?Trait.Location, null), Trait.get(&storage));

    Trait.set(&storage, .{ .page_id = 77, .slot_id = 3 });
    const location = Trait.get(&storage).?;
    try std.testing.expect(Trait.validate(&storage));
    try std.testing.expectEqual(@as(u32, 77), location.page_id);
    try std.testing.expectEqual(@as(u16, 3), location.slot_id);

    storage.page_id.setMax();
    try std.testing.expect(!Trait.validate(&storage));
    try std.testing.expectEqual(@as(?Trait.Location, null), Trait.get(&storage));

    Trait.clear(&storage);
    try std.testing.expect(Trait.validate(&storage));
    try std.testing.expectEqual(@as(?Trait.Location, null), Trait.get(&storage));
}
