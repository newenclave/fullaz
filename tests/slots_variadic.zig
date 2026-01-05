const std = @import("std");
const TestVariadic = @import("fullaz").slots.Variadic(u16, .little, false);

fn makeSequence(comptime N: usize) [N]u8 {
    return comptime blk: {
        var result: [N]u8 = undefined;
        for (0..N) |i| {
            result[i] = i +% 1;
        }
        break :blk result;
    };
}

test "variadic update slot after compact" {
    var buffer: [256]u8 = undefined;
    var slots = try TestVariadic.init(&buffer);
    slots.formatHeader();

    // Insert initial data
    const data1 = &makeSequence(20);
    const data2 = &makeSequence(30);
    const data3 = &makeSequence(25);

    _ = try slots.insert(data1);
    const idx_to_remove = try slots.insert(data2);
    _ = try slots.insert(data3);

    // Remove the middle slot (marks as invalid, stays in entries array)
    const available = try slots.availableAfterCompact();

    const res = try slots.canUpdate(idx_to_remove, data2.len + available);
    std.debug.print("Can update status before compact: {any}\n", .{res});

    try std.testing.expect(res == .need_compact);

    try slots.free(idx_to_remove);

    std.debug.print("Available after compact: {}\n", .{available});

    try slots.compactInPlace();

    // Calculate new size: old_len + 10
    const old_len = data2.len;
    const new_len = old_len + available;

    std.debug.print("Old length: {}, New length: {}, Available: {}\n", .{ old_len, new_len, available });

    // Update the removed slot with new data
    const update_buf = try slots.resizeGet(idx_to_remove, new_len);
    try std.testing.expectEqual(new_len, update_buf.len);

    // Fill with test pattern
    for (update_buf, 0..) |*byte, i| {
        byte.* = @intCast((i % 255) + 1);
    }

    // Verify the slot is now valid again
    const retrieved = try slots.get(idx_to_remove);
    try std.testing.expectEqual(new_len, retrieved.len);

    // Verify space is used
    const remaining_space = slots.availableSpace();
    const remaining_space_ac = try slots.availableAfterCompact();
    try std.testing.expect(remaining_space == 0);
    try std.testing.expect(remaining_space_ac == 0);
}
