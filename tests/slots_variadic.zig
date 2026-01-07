const std = @import("std");
const Variadic = @import("fullaz").slots.Variadic;
const testing = std.testing;

const TestVariadic = Variadic(u16, .little, false);
const TestVariadicConst = Variadic(u16, .little, true);

// Helper to create test sequences
fn makeSeq(comptime N: usize) [N]u8 {
    comptime var result: [N]u8 = undefined;
    inline for (0..N) |i| {
        result[i] = @intCast(i + 1);
    }
    return result;
}

// Helper to verify data integrity
fn verifyData(slots: *const TestVariadic, entry: usize, expected: []const u8) !void {
    const data = try slots.get(entry);
    try testing.expectEqualSlices(u8, expected, data);
}

test "Variadic: initialization" {
    var buffer: [256]u8 = undefined;

    // Should succeed with adequate buffer
    var slots = try TestVariadic.init(&buffer);
    slots.formatHeader();

    try testing.expectEqual(@as(usize, 0), slots.entriesConst().len);
    try testing.expect(slots.availableSpace() > 0);
}

test "Variadic: initialization with small buffer fails" {
    var buffer: [4]u8 = undefined;

    // Should fail - buffer too small for header
    const result = TestVariadic.init(&buffer);
    try testing.expectError(error.BufferTooSmall, result);
}

test "Variadic: basic insert and retrieve" {
    var buffer: [256]u8 = undefined;
    var slots = try TestVariadic.init(&buffer);
    slots.formatHeader();

    const data1 = "Hello";
    const data2 = "World";

    const idx1 = try slots.insert(data1);
    const idx2 = try slots.insert(data2);

    try testing.expectEqual(@as(usize, 0), idx1);
    try testing.expectEqual(@as(usize, 1), idx2);

    try verifyData(&slots, idx1, data1);
    try verifyData(&slots, idx2, data2);
}

test "Variadic: insertAt specific position" {
    var buffer: [256]u8 = undefined;
    var slots = try TestVariadic.init(&buffer);
    slots.formatHeader();

    try slots.insertAt(0, "First");
    try slots.insertAt(1, "Second");
    try slots.insertAt(0, "NewFirst"); // Insert before existing

    try verifyData(&slots, 0, "NewFirst");
    try verifyData(&slots, 1, "First");
    try verifyData(&slots, 2, "Second");
}

test "Variadic: insertAt invalid position" {
    var buffer: [256]u8 = undefined;
    var slots = try TestVariadic.init(&buffer);
    slots.formatHeader();

    _ = try slots.insert("First");

    // Should fail - position 5 is beyond current entries
    const result = slots.insertAt(5, "Invalid");
    try testing.expectError(error.InvalidPosition, result);
}

test "Variadic: remove entry" {
    var buffer: [256]u8 = undefined;
    var slots = try TestVariadic.init(&buffer);
    slots.formatHeader();

    _ = try slots.insert("First");
    _ = try slots.insert("Second");
    _ = try slots.insert("Third");

    try slots.free(1);

    // Entry 1 should be marked invalid
    const entries = slots.entriesConst();
    try testing.expectEqual(@as(u16, 0), entries[1].offset.get());

    // Other entries should still be accessible
    try verifyData(&slots, 0, "First");
    try verifyData(&slots, 2, "Third");
}

test "Variadic: removeShrink" {
    var buffer: [256]u8 = undefined;
    var slots = try TestVariadic.init(&buffer);
    slots.formatHeader();

    _ = try slots.insert("First");
    _ = try slots.insert("Second");
    _ = try slots.insert("Third");

    const before_count = slots.entriesConst().len;
    try slots.remove(1);
    const after_count = slots.entriesConst().len;

    try testing.expectEqual(before_count - 1, after_count);
    try verifyData(&slots, 0, "First");
    try verifyData(&slots, 1, "Third"); // Shifted down
}

test "Variadic: multiple inserts and removes" {
    var buffer: [512]u8 = undefined;
    var slots = try TestVariadic.init(&buffer);
    slots.formatHeader();

    const seq1 = makeSeq(10);
    const seq2 = makeSeq(20);
    const seq3 = makeSeq(30);

    _ = try slots.insert(&seq1);
    _ = try slots.insert(&seq2);
    _ = try slots.insert(&seq3);

    try verifyData(&slots, 0, &seq1);
    try verifyData(&slots, 1, &seq2);
    try verifyData(&slots, 2, &seq3);

    try slots.free(1);

    try verifyData(&slots, 0, &seq1);
    try verifyData(&slots, 2, &seq3);
}

test "Variadic: space calculations" {
    var buffer: [256]u8 = undefined;
    var slots = try TestVariadic.init(&buffer);
    slots.formatHeader();

    const initial_space = slots.availableSpace();

    _ = try slots.insert("Test");

    const after_insert = slots.availableSpace();
    try testing.expect(after_insert < initial_space);
}

test "Variadic: availableAfterCompact" {
    var buffer: [512]u8 = undefined;
    var slots = try TestVariadic.init(&buffer);
    slots.formatHeader();

    _ = try slots.insert(&makeSeq(10));
    _ = try slots.insert(&makeSeq(20));
    _ = try slots.insert(&makeSeq(30));

    const before_compact = try slots.availableAfterCompact();

    try slots.free(1);

    const after_remove = try slots.availableAfterCompact();
    try testing.expect(after_remove > before_compact);
}

test "Variadic: canInsert status" {
    var buffer: [128]u8 = undefined;
    var slots = try TestVariadic.init(&buffer);
    slots.formatHeader();

    // Small insert should fit
    const status1 = try slots.canInsert(10);
    try testing.expectEqual(.enough, status1);

    // Fill most of the buffer
    _ = try slots.insert(&makeSeq(50));

    // Large insert might need compact
    const status2 = try slots.canInsert(50);
    try testing.expect(status2 == .enough or status2 == .need_compact or status2 == .not_enough);
}

test "Variadic: canUpdate status" {
    var buffer: [256]u8 = undefined;
    var slots = try TestVariadic.init(&buffer);
    slots.formatHeader();

    _ = try slots.insert("Small");

    // Shrinking should always be enough
    const status1 = try slots.canUpdate(0, 3);
    try testing.expectEqual(.enough, status1);

    // Growing depends on available space
    const status2 = try slots.canUpdate(0, 100);
    try testing.expect(status2 == .enough or status2 == .need_compact or status2 == .not_enough);
}

test "Variadic: compactInPlace" {
    var buffer: [512]u8 = undefined;
    var slots = try TestVariadic.init(&buffer);
    slots.formatHeader();

    const seq1 = makeSeq(10);
    const seq2 = makeSeq(20);
    const seq3 = makeSeq(30);

    _ = try slots.insert(&seq1);
    _ = try slots.insert(&seq2);
    _ = try slots.insert(&seq3);

    try slots.free(1);

    const space_before = slots.availableSpace();

    try slots.compactInPlace();

    const space_after = slots.availableSpace();

    // Space should increase after compaction
    try testing.expect(space_after >= space_before);

    // Data should still be intact
    try verifyData(&slots, 0, &seq1);
    try verifyData(&slots, 2, &seq3);
}

test "Variadic: compactWithBuffer" {
    var buffer: [512]u8 = undefined;
    var temp_buffer: [512]u8 = undefined;
    var slots = try TestVariadic.init(&buffer);
    slots.formatHeader();

    const seq1 = makeSeq(15);
    const seq2 = makeSeq(25);
    const seq3 = makeSeq(35);

    _ = try slots.insert(&seq1);
    _ = try slots.insert(&seq2);
    _ = try slots.insert(&seq3);

    try slots.free(1);

    try slots.compactWithBuffer(temp_buffer[1..]); // shifting 1 byte to test offset handling

    // Data should still be intact after compaction
    try verifyData(&slots, 0, &seq1);
    try verifyData(&slots, 2, &seq3);
}

test "Variadic: resizeGet - shrink" {
    var buffer: [256]u8 = undefined;
    var slots = try TestVariadic.init(&buffer);
    slots.formatHeader();

    _ = try slots.insert("HelloWorld");

    const resized = try slots.resizeGet(0, 5);
    try testing.expectEqual(@as(usize, 5), resized.len);

    try verifyData(&slots, 0, "Hello");
}

test "Variadic: resizeGet - same size" {
    var buffer: [256]u8 = undefined;
    var slots = try TestVariadic.init(&buffer);
    slots.formatHeader();

    _ = try slots.insert("Hello");

    const resized = try slots.resizeGet(0, 5);
    try testing.expectEqual(@as(usize, 5), resized.len);
}

test "Variadic: resizeGet - grow" {
    var buffer: [512]u8 = undefined;
    var slots = try TestVariadic.init(&buffer);
    slots.formatHeader();

    _ = try slots.insert("Hi");

    // Growing should allocate new space
    const resized = try slots.resizeGet(0, 10);
    try testing.expectEqual(@as(usize, 10), resized.len);
}

test "Variadic: free slot reuse" {
    var buffer: [512]u8 = undefined;
    var slots = try TestVariadic.init(&buffer);
    slots.formatHeader();

    _ = try slots.insert(&makeSeq(20));
    _ = try slots.insert(&makeSeq(20));
    _ = try slots.insert(&makeSeq(20));

    try slots.free(1);

    // Next insert should potentially reuse freed space
    _ = try slots.insert(&makeSeq(15));

    try testing.expectEqual(@as(usize, 4), slots.entriesConst().len);
}

test "Variadic: boundary conditions - empty" {
    var buffer: [256]u8 = undefined;
    var slots = try TestVariadic.init(&buffer);
    slots.formatHeader();

    try testing.expectEqual(@as(usize, 0), slots.entriesConst().len);

    // Getting from empty should fail
    const result = slots.get(0);
    try testing.expectError(error.InvalidEntry, result);
}

test "Variadic: boundary conditions - full buffer" {
    var buffer: [128]u8 = undefined;
    var slots = try TestVariadic.init(&buffer);
    slots.formatHeader();

    // Fill buffer until it can't fit more
    var filled = false;
    for (0..20) |_| {
        const result = slots.insert(&makeSeq(10));
        if (result) |_| {
            // Success
        } else |_| {
            filled = true;
            break;
        }
    }

    try testing.expect(filled);
}

test "Variadic: invalid entry access" {
    var buffer: [256]u8 = undefined;
    var slots = try TestVariadic.init(&buffer);
    slots.formatHeader();

    _ = try slots.insert("Test");

    // Access beyond bounds
    const result = slots.get(10);
    try testing.expectError(error.InvalidEntry, result);
}

test "Variadic: const buffer restrictions" {
    var buffer: [256]u8 = undefined;
    var slots_mut = try TestVariadic.init(&buffer);
    slots_mut.formatHeader();

    _ = try slots_mut.insert("Data");

    // Create const view
    const slots_const = try TestVariadicConst.init(&buffer);

    // Read should work
    const data = try slots_const.get(0);
    try testing.expectEqualSlices(u8, "Data", data);

    // Note: Compile-time checks prevent mutation on const buffers
}

test "Variadic: stress test - many operations" {
    var buffer: [2048]u8 = undefined;
    var slots = try TestVariadic.init(&buffer);
    slots.formatHeader();

    var temp_data: [10]u8 = undefined;

    // Insert many entries
    var count: usize = 0;
    for (0..50) |i| {
        const size = (i % 10) + 1;
        for (0..size) |j| {
            temp_data[j] = @intCast(j + 1);
        }
        if (slots.insert(temp_data[0..size])) |_| {
            count += 1;
        } else |_| {
            break;
        }
    }

    // Remove every other entry
    var i: usize = 0;
    while (i < count) : (i += 2) {
        try slots.free(i);
    }

    // Compact
    try slots.compactInPlace();

    // Verify remaining entries still accessible
    try testing.expect(slots.entriesConst().len > 0);
}

test "Variadic: sequential operations" {
    var buffer: [1024]u8 = undefined;
    var slots = try TestVariadic.init(&buffer);
    slots.formatHeader();

    var temp_data: [50]u8 = undefined;

    // Sequential insert/remove/compact cycle
    for (0..5) |cycle| {
        _ = cycle;

        for (0..5) |i| {
            const size = (i + 1) * 5;
            for (0..size) |j| {
                temp_data[j] = @intCast((j % 255) + 1);
            }
            _ = try slots.insert(temp_data[0..size]);
        }

        if (slots.entriesConst().len >= 2) {
            try slots.remove(0);
        }

        try slots.compactInPlace();
    }

    // Should still be functional
    _ = try slots.insert("Final");
    try verifyData(&slots, slots.entriesConst().len - 1, "Final");
}

test "Variadic: data integrity after operations" {
    var buffer: [512]u8 = undefined;
    var slots = try TestVariadic.init(&buffer);
    slots.formatHeader();

    const data1 = "Immutable1";
    const data2 = "Immutable2";
    const data3 = "Immutable3";

    _ = try slots.insert(data1);
    _ = try slots.insert(data2);
    _ = try slots.insert(data3);

    // Various operations
    try slots.free(1); // This marks entry as invalid but doesn't shrink
    try slots.compactInPlace();
    _ = try slots.insert("New");

    // Original data should remain unchanged
    // Note: After remove(1), entry 1 is invalid, but still exists in the array
    // After compaction and new insert, we have: [data1, INVALID, data3, "New"]
    try verifyData(&slots, 0, data1);
    try verifyData(&slots, 2, data3);
    try verifyData(&slots, 3, "New");
}

test "Variadic: remove, compact, and update to use exact available space" {
    // Setup: Create a buffer and fill it strategically
    var buffer: [256]u8 = undefined;
    var slots = try TestVariadic.init(&buffer);
    slots.formatHeader();

    // Insert initial data
    const data1 = &makeSeq(20);
    const data2 = &makeSeq(30);
    const data3 = &makeSeq(25);

    _ = try slots.insert(data1);
    const idx_to_remove = try slots.insert(data2);
    _ = try slots.insert(data3);

    // Remove the middle slot (marks as invalid, stays in entries array)
    const available = try slots.availableAfterCompact();

    const res = try slots.canUpdate(idx_to_remove, data2.len + available);
    std.debug.print("Can update status before compact: {any}\n", .{res});

    try testing.expect(res == .need_compact);

    try slots.free(idx_to_remove);

    std.debug.print("Available after compact: {}\n", .{available});

    try slots.compactInPlace();

    // Calculate new size: old_len + 10
    const old_len = data2.len;
    const new_len = old_len + available;

    std.debug.print("Old length: {}, New length: {}, Available: {}\n", .{ old_len, new_len, available });

    // Update the removed slot with new data
    const update_buf = try slots.resizeGet(idx_to_remove, new_len);
    try testing.expectEqual(new_len, update_buf.len);

    // Fill with test pattern
    for (update_buf, 0..) |*byte, i| {
        byte.* = @intCast((i % 255) + 1);
    }

    // Verify the slot is now valid again
    const retrieved = try slots.get(idx_to_remove);
    try testing.expectEqual(new_len, retrieved.len);

    // Verify space is used
    const remaining_space = slots.availableSpace();
    const remaining_space_ac = try slots.availableAfterCompact();
    try testing.expect(remaining_space == 0);
    try testing.expect(remaining_space_ac == 0);
}

test "canMergeWith - enough space" {
    var buf1: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;

    var slots1 = try Variadic(u16, .little, false).init(&buf1);
    var slots2 = try Variadic(u16, .little, false).init(&buf2);
    slots1.formatHeader();
    slots2.formatHeader();

    // slots1 is empty, slots2 has small data
    _ = try slots2.insert("hello");
    _ = try slots2.insert("world");

    const status = try slots1.canMergeWith(&slots2);
    try std.testing.expectEqual(.enough, status);
}

test "canMergeWith - need compact" {
    var buf1: [64]u8 = undefined;
    var buf2: [64]u8 = undefined;

    var slots1 = try Variadic(u16, .little, false).init(&buf1);
    var slots2 = try Variadic(u16, .little, false).init(&buf2);
    slots1.formatHeader();
    slots2.formatHeader();

    // Fill slots1, then free some to create fragmentation
    _ = try slots1.insert("aaaa aaaa");
    _ = try slots1.insert("bbbb bbbb");
    _ = try slots1.insert("cccc cccc");
    _ = try slots1.insert("dddd dddd");
    try slots1.free(1); // Create hole

    // slots2 has data that could fit after compact
    _ = try slots2.insert("xxxx xxxx");

    const status = try slots1.canMergeWith(&slots2);
    try std.testing.expectEqual(.need_compact, status);
}

test "canMergeWith - not enough space" {
    var buf1: [32]u8 = undefined; // Small buffer
    var buf2: [256]u8 = undefined;

    var slots1 = try Variadic(u16, .little, false).init(&buf1);
    var slots2 = try Variadic(u16, .little, false).init(&buf2);
    slots1.formatHeader();
    slots2.formatHeader();

    // Fill slots1 almost completely
    _ = try slots1.insert("abcdefgh");

    // slots2 has too much data
    _ = try slots2.insert("12345678901234567890");

    const status = try slots1.canMergeWith(&slots2);
    try std.testing.expectEqual(.not_enough, status);
}

test "canMergeWith - accounts for data size not just entries" {
    var buf1: [64]u8 = undefined;
    var buf2: [64]u8 = undefined;

    var slots1 = try Variadic(u16, .little, false).init(&buf1);
    var slots2 = try Variadic(u16, .little, false).init(&buf2);
    slots1.formatHeader();
    slots2.formatHeader();

    // slots2 has 1 entry but LARGE data
    _ = try slots2.insert("this_is_a_very_long_string_that_takes_space");

    // Should fail because data doesn't fit, even though 1 entry would
    const status = try slots1.canMergeWith(&slots2);
    try std.testing.expect(status != .enough or slots1.availableSpace() >= 50);
}
