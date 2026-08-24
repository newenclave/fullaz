const std = @import("std");
const fullaz = @import("fullaz");

const extensions = fullaz.page.extensions;
const header = fullaz.page.header;
const LocationTrait = fullaz.storage.fsm.location.Trait(u32, u16, .little);
const Additional = extensions.Compose(.{
    .version = 4,
    .fields = .{
        extensions.field("fsm", LocationTrait),
    },
});
const Accessor = fullaz.storage.fsm.HeaderLocationAccessor(u32, u16, .little, Additional, "fsm");
const View = header.ViewImpl(u32, u16, Additional, .little, false);

test "FSM header location accessor reads, writes, and clears the configured extension field" {
    var buffer: [256]u8 = undefined;
    @memset(&buffer, 0);

    var view = View.init(&buffer);
    view.formatPage(42, 123, 8, 16);

    try std.testing.expectEqual(@as(?Accessor.Location, null), try Accessor.read(&buffer));

    try Accessor.write(&buffer, .{ .page_id = 77, .slot_id = 3 });
    const location = (try Accessor.read(&buffer)).?;
    try std.testing.expectEqual(@as(u32, 77), location.page_id);
    try std.testing.expectEqual(@as(u16, 3), location.slot_id);

    try Accessor.clear(&buffer);
    try std.testing.expectEqual(@as(?Accessor.Location, null), try Accessor.read(&buffer));
}

test "FSM header location accessor rejects a page with another layout version" {
    const WrongAdditional = extensions.Compose(.{
        .version = 5,
        .fields = .{
            extensions.field("fsm", LocationTrait),
        },
    });
    const WrongView = header.ViewImpl(u32, u16, WrongAdditional, .little, false);

    var buffer: [256]u8 = undefined;
    @memset(&buffer, 0);

    var view = WrongView.init(&buffer);
    view.formatPage(42, 123, 8, 16);

    try std.testing.expectError(Accessor.Error.UnsupportedVersion, Accessor.read(&buffer));
}
