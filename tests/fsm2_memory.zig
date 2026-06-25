const std = @import("std");
const fullaz = @import("fullaz");
const fsm2 = fullaz.storage.fsm2;

const Memory = fsm2.models.Memory(u32, u16);
const Map = fsm2.Fsm2(Memory);

test "Fsm2 memory: add, find, update, remove" {
    const allocator = std.testing.allocator;

    var model = try Memory.init(allocator);
    defer model.deinit();

    var map = Map.init(&model);
    defer map.deinit();

    // empty -> nothing fits
    try std.testing.expectEqual(@as(?u32, null), try map.find(10));

    // sorted by free: (1,10) (3,20) (2,30)
    try map.add(1, 10);
    try map.add(2, 30);
    try map.add(3, 20);

    // find returns the SMALLEST page with free >= size (proves sorted lowerBound)
    try std.testing.expectEqual(@as(?u32, 3), try map.find(15)); // free 20
    try std.testing.expectEqual(@as(?u32, 2), try map.find(25)); // free 30
    try std.testing.expectEqual(@as(?u32, null), try map.find(100));

    // update re-buckets: pid 1 grows to 50
    try map.update(1, 50);
    try std.testing.expectEqual(@as(?u32, 1), try map.find(40)); // free 50

    // remove drops a page
    try map.remove(2);
    try std.testing.expectEqual(@as(?u32, 1), try map.find(25)); // only 50 left >= 25
}
