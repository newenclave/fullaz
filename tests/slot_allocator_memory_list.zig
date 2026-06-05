const std = @import("std");
const fullaz = @import("fullaz");
const slot_allocator = fullaz.storage.slot_allocator;

const MemoryList = slot_allocator.models.MemoryList(u32, u16);

test "SlotAllocator memory_list: create the model" {
    var ml = try MemoryList.init(std.heap.page_allocator);
    defer ml.deinit();

    const idx = ml.lowerBoundElement(10);
    try std.testing.expectEqual(0, idx);

    _ = try ml.insert(1, 10);
    _ = try ml.insert(2, 20);
    _ = try ml.insert(3, 15);

    for (ml.ctx.pages.items) |pinfo| {
        std.debug.print("pid: {d}, size: {d}\n", .{ pinfo.pid, pinfo.size });
    }

    const idx2 = ml.lowerBoundElement(12);
    try std.testing.expectEqual(1, idx2);
}
