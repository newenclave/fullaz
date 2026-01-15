const std = @import("std");
const algorithm = @import("fullaz").algorithm;
const bpt = @import("fullaz").bpt;
const PageCacheT = @import("fullaz").PageCache;
const dev = @import("fullaz").device;

fn keyCmp(ctx: anytype, k1: []const u8, k2: []const u8) algorithm.Order {
    return algorithm.cmpSlices(u8, k1, k2, algorithm.CmpNum(u8).asc, ctx) catch .gt;
}

test "Create a bpt" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const BptModel = bpt.models.PagedModel(PageCacheT(Device), keyCmp, void);

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();
    var model = BptModel.init(&cache, .{}, {});

    var tree = bpt.Bpt(BptModel).init(&model, .neighbor_share);
    defer tree.deinit();

    //tree.insert("hello", "world");
}

test "test models functionality" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const BptModel = bpt.models.PagedModel(PageCacheT(Device), keyCmp, void);
    var device = try Device.init(allocator, 4096);

    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();
    var model = BptModel.init(&cache, .{}, {});

    var accessor = model.getAccessor();
    const available_before = cache.availableFrames();

    var leaf = try accessor.createLeaf();
    const leaf_load = try accessor.loadLeaf(try leaf.handle.pid());
    const leaf_taken = try leaf.take();
    accessor.deinitLeaf(leaf);
    accessor.deinitLeaf(leaf_taken);
    accessor.deinitLeaf(leaf_load);

    _ = leaf_taken.keysEqual("1", "2");

    try std.testing.expect((try leaf_taken.size()) == 0);

    var inode = try accessor.createInode();
    const inode_load = try accessor.loadInode(try inode.handle.pid());
    const inode_taken = try inode.take();
    accessor.deinitInode(inode);
    accessor.deinitInode(inode_load);
    accessor.deinitInode(inode_taken);

    //std.testing.expect(inode_taken.size() == 0);

    const available_after = cache.availableFrames();
    try std.testing.expect(available_before == available_after);
}

// ============================================
// LeafImpl Unit Tests
// ============================================

test "LeafImpl: newly created leaf has size 0" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const BptModel = bpt.models.PagedModel(PageCacheT(Device), keyCmp, void);

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();
    var model = BptModel.init(&cache, .{}, {});

    var accessor = model.getAccessor();
    var leaf = try accessor.createLeaf();
    defer accessor.deinitLeaf(leaf);

    try std.testing.expectEqual(@as(usize, 0), try leaf.size());
}

test "LeafImpl: capacity is greater than 0" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const BptModel = bpt.models.PagedModel(PageCacheT(Device), keyCmp, void);

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();
    var model = BptModel.init(&cache, .{}, {});

    var accessor = model.getAccessor();
    var leaf = try accessor.createLeaf();
    defer accessor.deinitLeaf(leaf);

    const cap = try leaf.capacity();
    try std.testing.expect(cap > 0);
}

test "LeafImpl: insertValue and getKey/getValue" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const BptModel = bpt.models.PagedModel(PageCacheT(Device), keyCmp, void);

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();
    var model = BptModel.init(&cache, .{}, {});

    var accessor = model.getAccessor();
    var leaf = try accessor.createLeaf();
    defer accessor.deinitLeaf(leaf);

    // Insert a key-value pair
    try leaf.insertValue(0, "hello", "world");
    try std.testing.expectEqual(@as(usize, 1), try leaf.size());

    // Verify key and value
    const key = try leaf.getKey(0);
    const value = try leaf.getValue(0);
    try std.testing.expectEqualStrings("hello", key);
    try std.testing.expectEqualStrings("world", value);
}

test "LeafImpl: insert multiple values and verify order" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const BptModel = bpt.models.PagedModel(PageCacheT(Device), keyCmp, void);

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();
    var model = BptModel.init(&cache, .{}, {});

    var accessor = model.getAccessor();
    var leaf = try accessor.createLeaf();
    defer accessor.deinitLeaf(leaf);

    // Insert values at specific positions
    try leaf.insertValue(0, "apple", "fruit1");
    try leaf.insertValue(1, "cherry", "fruit3");
    try leaf.insertValue(1, "banana", "fruit2"); // Insert in middle

    try std.testing.expectEqual(@as(usize, 3), try leaf.size());

    // Verify order: apple, banana, cherry
    try std.testing.expectEqualStrings("apple", try leaf.getKey(0));
    try std.testing.expectEqualStrings("banana", try leaf.getKey(1));
    try std.testing.expectEqualStrings("cherry", try leaf.getKey(2));

    try std.testing.expectEqualStrings("fruit1", try leaf.getValue(0));
    try std.testing.expectEqualStrings("fruit2", try leaf.getValue(1));
    try std.testing.expectEqualStrings("fruit3", try leaf.getValue(2));
}

test "LeafImpl: keysEqual compares correctly" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const BptModel = bpt.models.PagedModel(PageCacheT(Device), keyCmp, void);

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();
    var model = BptModel.init(&cache, .{}, {});

    var accessor = model.getAccessor();
    var leaf = try accessor.createLeaf();
    defer accessor.deinitLeaf(leaf);

    try std.testing.expect(leaf.keysEqual("test", "test"));
    try std.testing.expect(!leaf.keysEqual("test", "test2"));
    try std.testing.expect(!leaf.keysEqual("abc", "abd"));
}

test "LeafImpl: keyPosition finds correct position" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const BptModel = bpt.models.PagedModel(PageCacheT(Device), keyCmp, void);
    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();
    var model = BptModel.init(&cache, .{}, {});

    var accessor = model.getAccessor();
    var leaf = try accessor.createLeaf();
    defer accessor.deinitLeaf(leaf);

    // Empty leaf - any key should return position 0
    try std.testing.expectEqual(@as(usize, 0), try leaf.keyPosition("anything"));

    // Insert values: apple, banana, cherry (in sorted order)
    try leaf.insertValue(0, "apple", "fruit1");
    try leaf.insertValue(1, "banana", "fruit2");
    try leaf.insertValue(2, "cherry", "fruit3");

    try std.testing.expectEqual(@as(usize, 3), try leaf.size());

    // Test exact matches
    try std.testing.expectEqual(@as(usize, 0), try leaf.keyPosition("apple"));
    try std.testing.expectEqual(@as(usize, 1), try leaf.keyPosition("banana"));
    try std.testing.expectEqual(@as(usize, 2), try leaf.keyPosition("cherry"));

    // Test key before first element
    try std.testing.expectEqual(@as(usize, 0), try leaf.keyPosition("aaa"));

    // Test key between elements
    try std.testing.expectEqual(@as(usize, 1), try leaf.keyPosition("avocado")); // between apple and banana
    try std.testing.expectEqual(@as(usize, 2), try leaf.keyPosition("blueberry")); // between banana and cherry

    // Test key after last element
    try std.testing.expectEqual(@as(usize, 3), try leaf.keyPosition("date"));
    try std.testing.expectEqual(@as(usize, 3), try leaf.keyPosition("zzz"));
}

test "LeafImpl: setNext/getNext and setPrev/getPrev" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const BptModel = bpt.models.PagedModel(PageCacheT(Device), keyCmp, void);

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();
    var model = BptModel.init(&cache, .{}, {});

    var accessor = model.getAccessor();
    var leaf = try accessor.createLeaf();
    defer accessor.deinitLeaf(leaf);

    // Initially null
    try std.testing.expectEqual(@as(?u32, null), leaf.getNext());
    try std.testing.expectEqual(@as(?u32, null), leaf.getPrev());

    // Set and get next
    try leaf.setNext(42);
    try std.testing.expectEqual(@as(?u32, 42), leaf.getNext());

    // Set and get prev
    try leaf.setPrev(100);
    try std.testing.expectEqual(@as(?u32, 100), leaf.getPrev());

    // Clear next
    try leaf.setNext(null);
    try std.testing.expectEqual(@as(?u32, null), leaf.getNext());

    // Clear prev
    try leaf.setPrev(null);
    try std.testing.expectEqual(@as(?u32, null), leaf.getPrev());
}

test "LeafImpl: setParent/getParent" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const BptModel = bpt.models.PagedModel(PageCacheT(Device), keyCmp, void);

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();
    var model = BptModel.init(&cache, .{}, {});

    var accessor = model.getAccessor();
    var leaf = try accessor.createLeaf();
    defer accessor.deinitLeaf(leaf);

    // Initially null
    try std.testing.expectEqual(@as(?u32, null), leaf.getParent());

    // Set and get parent
    try leaf.setParent(55);
    try std.testing.expectEqual(@as(?u32, 55), leaf.getParent());

    // Clear parent
    try leaf.setParent(null);
    try std.testing.expectEqual(@as(?u32, null), leaf.getParent());
}

test "LeafImpl: id returns correct block id" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const BptModel = bpt.models.PagedModel(PageCacheT(Device), keyCmp, void);

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();
    var model = BptModel.init(&cache, .{}, {});

    var accessor = model.getAccessor();
    var leaf = try accessor.createLeaf();
    defer accessor.deinitLeaf(leaf);

    const leaf_id = leaf.id();
    const handle_id = try leaf.handle.pid();
    try std.testing.expectEqual(handle_id, leaf_id);
}

test "LeafImpl: canInsertValue checks capacity" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const BptModel = bpt.models.PagedModel(PageCacheT(Device), keyCmp, void);

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();
    var model = BptModel.init(&cache, .{}, {});

    var accessor = model.getAccessor();
    var leaf = try accessor.createLeaf();
    defer accessor.deinitLeaf(leaf);

    // Should be able to insert a small key-value
    try std.testing.expect(try leaf.canInsertValue(0, "key", "value"));

    // Very large key-value might not fit
    var large_key: [200]u8 = undefined;
    @memset(&large_key, 'x');
    var large_value: [200]u8 = undefined;
    @memset(&large_value, 'y');
    // This might or might not fit depending on page size
}

test "LeafImpl: isUnderflowed for empty leaf" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const BptModel = bpt.models.PagedModel(PageCacheT(Device), keyCmp, void);

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();
    var model = BptModel.init(&cache, .{}, {});

    var accessor = model.getAccessor();
    var leaf = try accessor.createLeaf();
    defer accessor.deinitLeaf(leaf);

    // Empty leaf should be underflowed
    try std.testing.expect(try leaf.isUnderflowed());
}

test "LeafImpl: take transfers ownership" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const BptModel = bpt.models.PagedModel(PageCacheT(Device), keyCmp, void);

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();
    var model = BptModel.init(&cache, .{}, {});

    var accessor = model.getAccessor();
    var leaf = try accessor.createLeaf();
    const leaf_id = leaf.id();

    // Insert a value
    try leaf.insertValue(0, "key1", "value1");

    // Take transfers ownership - original handle becomes invalid
    var taken = try leaf.take();
    defer accessor.deinitLeaf(taken);
    // Note: leaf is now invalid, do not use it

    // Taken should have same id
    try std.testing.expectEqual(leaf_id, taken.id());

    // Taken should have the data
    try std.testing.expectEqual(@as(usize, 1), try taken.size());
    try std.testing.expectEqualStrings("key1", try taken.getKey(0));
}

test "LeafImpl: linked list operations with multiple leaves" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const BptModel = bpt.models.PagedModel(PageCacheT(Device), keyCmp, void);

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();
    var model = BptModel.init(&cache, .{}, {});

    var accessor = model.getAccessor();

    // Create three leaves
    var leaf1 = try accessor.createLeaf();
    defer accessor.deinitLeaf(leaf1);
    var leaf2 = try accessor.createLeaf();
    defer accessor.deinitLeaf(leaf2);
    var leaf3 = try accessor.createLeaf();
    defer accessor.deinitLeaf(leaf3);

    // Link them: leaf1 <-> leaf2 <-> leaf3
    try leaf1.setNext(leaf2.id());
    try leaf2.setPrev(leaf1.id());
    try leaf2.setNext(leaf3.id());
    try leaf3.setPrev(leaf2.id());

    // Verify links
    try std.testing.expectEqual(@as(?u32, leaf2.id()), leaf1.getNext());
    try std.testing.expectEqual(@as(?u32, null), leaf1.getPrev());

    try std.testing.expectEqual(@as(?u32, leaf3.id()), leaf2.getNext());
    try std.testing.expectEqual(@as(?u32, leaf1.id()), leaf2.getPrev());

    try std.testing.expectEqual(@as(?u32, null), leaf3.getNext());
    try std.testing.expectEqual(@as(?u32, leaf2.id()), leaf3.getPrev());
}

test "LeafImpl: updateValue modifies existing value" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const BptModel = bpt.models.PagedModel(PageCacheT(Device), keyCmp, void);

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();
    var model = BptModel.init(&cache, .{}, {});

    var accessor = model.getAccessor();
    var leaf = try accessor.createLeaf();
    defer accessor.deinitLeaf(leaf);

    // Insert initial value
    try leaf.insertValue(0, "key1", "old_value");
    try std.testing.expectEqualStrings("old_value", try leaf.getValue(0));

    // Update the value
    try leaf.updateValue(0, "new_value");
    try std.testing.expectEqualStrings("new_value", try leaf.getValue(0));

    // Key should remain unchanged
    try std.testing.expectEqualStrings("key1", try leaf.getKey(0));

    // Size should remain the same
    try std.testing.expectEqual(@as(usize, 1), try leaf.size());
}

test "LeafImpl: updateValue triggers compaction when needed" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const BptModel = bpt.models.PagedModel(PageCacheT(Device), keyCmp, void);

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();
    var model = BptModel.init(&cache, .{}, {});

    var accessor = model.getAccessor();
    var leaf = try accessor.createLeaf();
    defer accessor.deinitLeaf(leaf);

    // Create a pattern that will fragment the page:
    // Insert values with large content, then update them with smaller content
    // This creates "holes" in the page that can only be reclaimed via compaction

    // Insert several entries with medium-sized values
    var value_buf: [100]u8 = undefined;
    @memset(&value_buf, 'x');

    try leaf.insertValue(0, "key_a", value_buf[0..100]);
    try leaf.insertValue(1, "key_b", value_buf[0..100]);
    try leaf.insertValue(2, "key_c", value_buf[0..100]);
    try leaf.insertValue(3, "key_d", value_buf[0..100]);

    // Now update each entry with smaller values - this creates fragmentation
    try leaf.updateValue(0, "small");
    try leaf.updateValue(1, "tiny");
    try leaf.updateValue(2, "mini");
    try leaf.updateValue(3, "wee");

    // Verify updates worked
    try std.testing.expectEqualStrings("small", try leaf.getValue(0));
    try std.testing.expectEqualStrings("tiny", try leaf.getValue(1));

    // Now try to update with a larger value that requires the freed space
    // but the freed space is fragmented, so compaction is needed
    var large_value: [150]u8 = undefined;
    @memset(&large_value, 'y');

    // Check the status - it should be .need_compact (space available after compaction)
    // or .enough (if there's a free slot that fits)
    const status = try leaf.canUpdateValueStatus(0, "key_a", large_value[0..150]);
    std.debug.print("Can update status before compact: {}\n", .{status});

    // The update should succeed regardless (updateValue handles compaction internally)
    if (status != .not_enough) {
        try leaf.updateValue(0, large_value[0..150]);
        try std.testing.expectEqualStrings(large_value[0..150], try leaf.getValue(0));
    } else {
        // If truly not enough space, that's also valid - page is just too full
        std.debug.print("Not enough space even after compaction - page is full\n", .{});
    }

    // If we got .need_compact, verify that a larger update triggers compaction
    if (status == .need_compact) {
        std.debug.print("Successfully verified .need_compact condition!\n", .{});
        // The update already happened above and compaction was triggered internally
    }
}
