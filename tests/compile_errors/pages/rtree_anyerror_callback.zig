const fullaz = @import("fullaz");

const Schema = fullaz.pages.Schema(.{ .page_id = u32 })
    .add("spatial", fullaz.pages.rtree(.{
    .Coord = i64,
    .dimensions = 2,
    .maximum_entries = 4,
    .maximum_value_size = 16,
}));
const Db = fullaz.pages.MemoryDatabase(Schema);
const Binding = Schema.trait("spatial").Binding(Db.BackendType);
const Proxy = Binding.ConstProxy;
const Box = Proxy.BoundingBox;

const Callback = struct {
    fn call(_: void, _: Box, _: []const u8) anyerror!void {}
};

comptime {
    _ = @TypeOf(Proxy.search(
        @as(*const Proxy, undefined),
        Box.initWith(.{ 0, 0 }, .{ 1, 1 }),
        {},
        Callback.call,
    ));
}
