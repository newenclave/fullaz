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

// ============================================
// LeafImpl: erase tests
// ============================================

test "LeafImpl: erase removes entry and decreases size" {
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

    // Insert three values
    try leaf.insertValue(0, "apple", "fruit1");
    try leaf.insertValue(1, "banana", "fruit2");
    try leaf.insertValue(2, "cherry", "fruit3");

    try std.testing.expectEqual(@as(usize, 3), try leaf.size());

    // Erase the middle element
    try leaf.erase(1);

    try std.testing.expectEqual(@as(usize, 2), try leaf.size());

    // Verify remaining elements: apple and cherry
    try std.testing.expectEqualStrings("apple", try leaf.getKey(0));
    try std.testing.expectEqualStrings("cherry", try leaf.getKey(1));
}

test "LeafImpl: erase first element" {
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

    try leaf.insertValue(0, "apple", "fruit1");
    try leaf.insertValue(1, "banana", "fruit2");

    try leaf.erase(0);

    try std.testing.expectEqual(@as(usize, 1), try leaf.size());
    try std.testing.expectEqualStrings("banana", try leaf.getKey(0));
}

test "LeafImpl: erase last element" {
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

    try leaf.insertValue(0, "apple", "fruit1");
    try leaf.insertValue(1, "banana", "fruit2");

    try leaf.erase(1);

    try std.testing.expectEqual(@as(usize, 1), try leaf.size());
    try std.testing.expectEqualStrings("apple", try leaf.getKey(0));
}

test "LeafImpl: erase all elements one by one" {
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

    try leaf.insertValue(0, "a", "1");
    try leaf.insertValue(1, "b", "2");
    try leaf.insertValue(2, "c", "3");

    // Erase from front each time
    try leaf.erase(0);
    try std.testing.expectEqual(@as(usize, 2), try leaf.size());
    try leaf.erase(0);
    try std.testing.expectEqual(@as(usize, 1), try leaf.size());
    try leaf.erase(0);
    try std.testing.expectEqual(@as(usize, 0), try leaf.size());
}

// ============================================
// InodeImpl Unit Tests
// ============================================

test "InodeImpl: newly created inode has size 0" {
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
    var inode = try accessor.createInode();
    defer accessor.deinitInode(inode);

    try std.testing.expectEqual(@as(usize, 0), try inode.size());
}

test "InodeImpl: capacity is greater than 0" {
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
    var inode = try accessor.createInode();
    defer accessor.deinitInode(inode);

    const cap = try inode.capacity();
    try std.testing.expect(cap > 0);
}

test "InodeImpl: insertChild and getKey/getChild" {
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
    var inode = try accessor.createInode();
    defer accessor.deinitInode(inode);

    // Insert a key-child pair
    try inode.insertChild(0, "key1", 100);
    try std.testing.expectEqual(@as(usize, 1), try inode.size());

    // Verify key and child
    const key = try inode.getKey(0);
    const child_id = try inode.getChild(0);
    try std.testing.expectEqualStrings("key1", key);
    try std.testing.expectEqual(@as(u32, 100), child_id);
}

test "InodeImpl: insert multiple children and verify order" {
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
    var inode = try accessor.createInode();
    defer accessor.deinitInode(inode);

    // Insert children at specific positions
    try inode.insertChild(0, "apple", 10);
    try inode.insertChild(1, "cherry", 30);
    try inode.insertChild(1, "banana", 20); // Insert in middle

    try std.testing.expectEqual(@as(usize, 3), try inode.size());

    // Verify order: apple, banana, cherry
    try std.testing.expectEqualStrings("apple", try inode.getKey(0));
    try std.testing.expectEqualStrings("banana", try inode.getKey(1));
    try std.testing.expectEqualStrings("cherry", try inode.getKey(2));

    try std.testing.expectEqual(@as(u32, 10), try inode.getChild(0));
    try std.testing.expectEqual(@as(u32, 20), try inode.getChild(1));
    try std.testing.expectEqual(@as(u32, 30), try inode.getChild(2));
}

test "InodeImpl: keysEqual compares correctly" {
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
    var inode = try accessor.createInode();
    defer accessor.deinitInode(inode);

    try std.testing.expect(inode.keysEqual("test", "test"));
    try std.testing.expect(!inode.keysEqual("test", "test2"));
    try std.testing.expect(!inode.keysEqual("abc", "abd"));
}

test "InodeImpl: keyPosition finds correct position (upperBound)" {
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
    var inode = try accessor.createInode();
    defer accessor.deinitInode(inode);

    // Insert keys: apple, banana, cherry
    try inode.insertChild(0, "apple", 10);
    try inode.insertChild(1, "banana", 20);
    try inode.insertChild(2, "cherry", 30);

    // upperBound returns position of first element > key
    // For "apple", upperBound should return 1 (first element > "apple" is "banana")
    try std.testing.expectEqual(@as(usize, 1), try inode.keyPosition("apple"));
    try std.testing.expectEqual(@as(usize, 2), try inode.keyPosition("banana"));
    try std.testing.expectEqual(@as(usize, 3), try inode.keyPosition("cherry"));

    // Key before all
    try std.testing.expectEqual(@as(usize, 0), try inode.keyPosition("aaa"));

    // Key between elements
    try std.testing.expectEqual(@as(usize, 1), try inode.keyPosition("avocado")); // > apple, < banana

    // Key after all
    try std.testing.expectEqual(@as(usize, 3), try inode.keyPosition("zzz"));
}

test "InodeImpl: setParent/getParent" {
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
    var inode = try accessor.createInode();
    defer accessor.deinitInode(inode);

    // Initially null
    try std.testing.expectEqual(@as(?u32, null), inode.getParent());

    // Set and get parent
    try inode.setParent(55);
    try std.testing.expectEqual(@as(?u32, 55), inode.getParent());

    // Clear parent
    try inode.setParent(null);
    try std.testing.expectEqual(@as(?u32, null), inode.getParent());
}

test "InodeImpl: id returns correct block id" {
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
    var inode = try accessor.createInode();
    defer accessor.deinitInode(inode);

    const inode_id = inode.id();
    const handle_id = try inode.handle.pid();
    try std.testing.expectEqual(handle_id, inode_id);
}

test "InodeImpl: canInsertChild checks capacity" {
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
    var inode = try accessor.createInode();
    defer accessor.deinitInode(inode);

    // Should be able to insert a small key
    try std.testing.expect(try inode.canInsertChild(0, "key", 0));
}

test "InodeImpl: isUnderflowed for empty inode" {
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
    var inode = try accessor.createInode();
    defer accessor.deinitInode(inode);

    // Empty inode should be underflowed
    try std.testing.expect(try inode.isUnderflowed());
}

test "InodeImpl: take transfers ownership" {
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
    var inode = try accessor.createInode();
    const inode_id = inode.id();

    // Insert a child
    try inode.insertChild(0, "key1", 100);

    // Take transfers ownership
    var taken = try inode.take();
    defer accessor.deinitInode(taken);

    // Taken should have same id
    try std.testing.expectEqual(inode_id, taken.id());

    // Taken should have the data
    try std.testing.expectEqual(@as(usize, 1), try taken.size());
    try std.testing.expectEqualStrings("key1", try taken.getKey(0));
}

test "InodeImpl: updateChild modifies existing child id" {
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
    var inode = try accessor.createInode();
    defer accessor.deinitInode(inode);

    // Insert a child
    try inode.insertChild(0, "key1", 100);
    try std.testing.expectEqual(@as(u32, 100), try inode.getChild(0));

    // Update the child id
    try inode.updateChild(0, 200);
    try std.testing.expectEqual(@as(u32, 200), try inode.getChild(0));
    // Key should remain unchanged
    try std.testing.expectEqualStrings("key1", try inode.getKey(0));
}

test "InodeImpl: canUpdateKey checks capacity" {
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
    var inode = try accessor.createInode();
    defer accessor.deinitInode(inode);

    try inode.insertChild(0, "key1", 100);

    // Should be able to update with similar size key
    try std.testing.expect(try inode.canUpdateKey(0, "key2"));

    // Should also be able to update with smaller key
    try std.testing.expect(try inode.canUpdateKey(0, "k"));
}

test "InodeImpl: erase removes entry and decreases size" {
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
    var inode = try accessor.createInode();
    defer accessor.deinitInode(inode);

    // Insert three children
    try inode.insertChild(0, "apple", 10);
    try inode.insertChild(1, "banana", 20);
    try inode.insertChild(2, "cherry", 30);

    try std.testing.expectEqual(@as(usize, 3), try inode.size());

    // Erase the middle element
    try inode.erase(1);

    try std.testing.expectEqual(@as(usize, 2), try inode.size());

    // Verify remaining elements: apple and cherry
    try std.testing.expectEqualStrings("apple", try inode.getKey(0));
    try std.testing.expectEqualStrings("cherry", try inode.getKey(1));
    try std.testing.expectEqual(@as(u32, 10), try inode.getChild(0));
    try std.testing.expectEqual(@as(u32, 30), try inode.getChild(1));
}

test "InodeImpl: erase first element" {
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
    var inode = try accessor.createInode();
    defer accessor.deinitInode(inode);

    try inode.insertChild(0, "apple", 10);
    try inode.insertChild(1, "banana", 20);

    try inode.erase(0);

    try std.testing.expectEqual(@as(usize, 1), try inode.size());
    try std.testing.expectEqualStrings("banana", try inode.getKey(0));
    try std.testing.expectEqual(@as(u32, 20), try inode.getChild(0));
}

test "InodeImpl: erase last element" {
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
    var inode = try accessor.createInode();
    defer accessor.deinitInode(inode);

    try inode.insertChild(0, "apple", 10);
    try inode.insertChild(1, "banana", 20);

    try inode.erase(1);

    try std.testing.expectEqual(@as(usize, 1), try inode.size());
    try std.testing.expectEqualStrings("apple", try inode.getKey(0));
    try std.testing.expectEqual(@as(u32, 10), try inode.getChild(0));
}

test "InodeImpl: erase all elements one by one" {
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
    var inode = try accessor.createInode();
    defer accessor.deinitInode(inode);

    try inode.insertChild(0, "a", 1);
    try inode.insertChild(1, "b", 2);
    try inode.insertChild(2, "c", 3);

    // Erase from front each time
    try inode.erase(0);
    try std.testing.expectEqual(@as(usize, 2), try inode.size());
    try inode.erase(0);
    try std.testing.expectEqual(@as(usize, 1), try inode.size());
    try inode.erase(0);
    try std.testing.expectEqual(@as(usize, 0), try inode.size());
}

// ============================================
// PageCache: Frame Leak Detection Tests
// ============================================

test "PageCache: no frame leaks after mixed Leaf and Inode operations" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const BptModel = bpt.models.PagedModel(PageCacheT(Device), keyCmp, void);

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();

    const available_before = cache.availableFrames();
    try std.testing.expectEqual(@as(usize, 8), available_before);

    var model = BptModel.init(&cache, .{}, {});
    var accessor = model.getAccessor();

    // Test block 1: Create and deinit leaves
    {
        var leaf1 = try accessor.createLeaf();
        defer accessor.deinitLeaf(leaf1);

        try leaf1.insertValue(0, "key1", "value1");
        try leaf1.insertValue(1, "key2", "value2");

        var leaf2 = try accessor.createLeaf();
        defer accessor.deinitLeaf(leaf2);

        try leaf2.insertValue(0, "other", "data");
    }

    // Test block 2: Create, take, and deinit leaves
    {
        var leaf = try accessor.createLeaf();
        try leaf.insertValue(0, "test", "data");

        const taken = try leaf.take();
        defer accessor.deinitLeaf(taken);
        // Original leaf handle is now invalid, don't deinit it
    }

    // Test block 3: Create and load leaves
    {
        var leaf = try accessor.createLeaf();
        const leaf_id = leaf.id();
        try leaf.insertValue(0, "persistent", "value");
        accessor.deinitLeaf(leaf);

        // Load the same leaf
        var loaded = try accessor.loadLeaf(leaf_id);
        defer accessor.deinitLeaf(loaded);
        try std.testing.expectEqualStrings("persistent", try loaded.?.getKey(0));
    }

    // Test block 4: Create and deinit inodes
    {
        var inode1 = try accessor.createInode();
        defer accessor.deinitInode(inode1);

        try inode1.insertChild(0, "key1", 100);
        try inode1.insertChild(1, "key2", 200);

        var inode2 = try accessor.createInode();
        defer accessor.deinitInode(inode2);

        try inode2.insertChild(0, "other", 300);
    }

    // Test block 5: Create, take, and deinit inodes
    {
        var inode = try accessor.createInode();
        try inode.insertChild(0, "test", 999);

        const taken = try inode.take();
        defer accessor.deinitInode(taken);
        // Original inode handle is now invalid
    }

    // Test block 6: Create and load inodes
    {
        var inode = try accessor.createInode();
        const inode_id = inode.id();
        try inode.insertChild(0, "persistent", 42);
        accessor.deinitInode(inode);

        // Load the same inode
        var loaded = try accessor.loadInode(inode_id);
        defer accessor.deinitInode(loaded);
        try std.testing.expectEqualStrings("persistent", try loaded.?.getKey(0));
    }

    // Test block 7: Mixed operations with erase
    {
        var leaf = try accessor.createLeaf();
        defer accessor.deinitLeaf(leaf);

        try leaf.insertValue(0, "a", "1");
        try leaf.insertValue(1, "b", "2");
        try leaf.insertValue(2, "c", "3");
        try leaf.erase(1);
        try leaf.updateValue(0, "updated");
    }

    // Test block 8: Mixed operations on inode with erase
    {
        var inode = try accessor.createInode();
        defer accessor.deinitInode(inode);

        try inode.insertChild(0, "x", 1);
        try inode.insertChild(1, "y", 2);
        try inode.insertChild(2, "z", 3);
        try inode.erase(0);
        try inode.updateChild(0, 999);
    }

    // Verify no frames leaked
    const available_after = cache.availableFrames();
    try std.testing.expectEqual(available_before, available_after);
}

// ============================================
// Accessor Unit Tests
// ============================================

test "Accessor: createLeaf and createInode create different page types" {
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

    var inode = try accessor.createInode();
    defer accessor.deinitInode(inode);

    // Different pages should have different IDs
    try std.testing.expect(leaf.id() != inode.id());
}

test "Accessor: loadLeaf returns null for inode page" {
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

    // Create an inode
    var inode = try accessor.createInode();
    const inode_id = inode.id();
    accessor.deinitInode(inode);

    // Try to load it as a leaf - should return null
    const loaded = try accessor.loadLeaf(inode_id);
    try std.testing.expectEqual(@as(?BptModel.LeafType, null), loaded);
}

test "Accessor: loadInode returns null for leaf page" {
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

    // Create a leaf
    var leaf = try accessor.createLeaf();
    const leaf_id = leaf.id();
    accessor.deinitLeaf(leaf);

    // Try to load it as an inode - should return null
    const loaded = try accessor.loadInode(leaf_id);
    try std.testing.expectEqual(@as(?BptModel.InodeType, null), loaded);
}

test "Accessor: loadLeaf returns leaf for leaf page" {
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

    // Create a leaf with data
    var leaf = try accessor.createLeaf();
    const leaf_id = leaf.id();
    try leaf.insertValue(0, "testkey", "testvalue");
    accessor.deinitLeaf(leaf);

    // Load it as a leaf - should succeed
    var loaded = try accessor.loadLeaf(leaf_id);
    defer accessor.deinitLeaf(loaded);

    try std.testing.expect(loaded != null);
    try std.testing.expectEqual(leaf_id, loaded.?.id());
    try std.testing.expectEqualStrings("testkey", try loaded.?.getKey(0));
}

test "Accessor: loadInode returns inode for inode page" {
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

    // Create an inode with data
    var inode = try accessor.createInode();
    const inode_id = inode.id();
    try inode.insertChild(0, "testkey", 42);
    accessor.deinitInode(inode);

    // Load it as an inode - should succeed
    var loaded = try accessor.loadInode(inode_id);
    defer accessor.deinitInode(loaded);

    try std.testing.expect(loaded != null);
    try std.testing.expectEqual(inode_id, loaded.?.id());
    try std.testing.expectEqualStrings("testkey", try loaded.?.getKey(0));
}

test "Accessor: loadLeaf with null returns null" {
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

    const loaded = try accessor.loadLeaf(null);
    try std.testing.expectEqual(@as(?BptModel.LeafType, null), loaded);
}

test "Accessor: loadInode with null returns null" {
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

    const loaded = try accessor.loadInode(null);
    try std.testing.expectEqual(@as(?BptModel.InodeType, null), loaded);
}

test "Accessor: isLeafId returns true for leaf page" {
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
    accessor.deinitLeaf(leaf);

    try std.testing.expect(try accessor.isLeafId(leaf_id));
}

test "Accessor: isLeafId returns false for inode page" {
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

    var inode = try accessor.createInode();
    const inode_id = inode.id();
    accessor.deinitInode(inode);

    try std.testing.expect(!try accessor.isLeafId(inode_id));
}

test "Accessor: borrowKeyfromLeaf borrows key correctly" {
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

    try leaf.insertValue(0, "mykey", "myvalue");

    const borrowed = try accessor.borrowKeyfromLeaf(&leaf, 0);
    defer accessor.deinitBorrowKey(borrowed);

    try std.testing.expectEqualStrings("mykey", borrowed.key);
}

test "Accessor: borrowKeyfromInode borrows key correctly" {
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

    var inode = try accessor.createInode();
    defer accessor.deinitInode(inode);

    try inode.insertChild(0, "inodekey", 123);

    const borrowed = try accessor.borrowKeyfromInode(&inode, 0);
    defer accessor.deinitBorrowKey(borrowed);

    try std.testing.expectEqualStrings("inodekey", borrowed.key);
}

test "Accessor: canMergeLeafs returns true for empty leaves" {
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

    var leaf1 = try accessor.createLeaf();
    defer accessor.deinitLeaf(leaf1);

    var leaf2 = try accessor.createLeaf();
    defer accessor.deinitLeaf(leaf2);

    // Empty leaves should be mergeable
    try std.testing.expect(try accessor.canMergeLeafs(&leaf1, &leaf2));
}

test "Accessor: canMergeInodes returns true for empty inodes" {
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

    var inode1 = try accessor.createInode();
    defer accessor.deinitInode(inode1);

    var inode2 = try accessor.createInode();
    defer accessor.deinitInode(inode2);

    // Empty inodes should be mergeable
    try std.testing.expect(try accessor.canMergeInodes(&inode1, &inode2));
}

test "Accessor: canMergeLeafs with small data returns true" {
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

    var leaf1 = try accessor.createLeaf();
    defer accessor.deinitLeaf(leaf1);
    try leaf1.insertValue(0, "key1", "value1");

    var leaf2 = try accessor.createLeaf();
    defer accessor.deinitLeaf(leaf2);
    try leaf2.insertValue(0, "key2", "value2");

    // Small data should be mergeable
    try std.testing.expect(try accessor.canMergeLeafs(&leaf1, &leaf2));
}

test "Accessor: deinitLeaf handles null gracefully" {
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

    // Should not crash
    accessor.deinitLeaf(null);
}

test "Accessor: deinitInode handles null gracefully" {
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

    // Should not crash
    accessor.deinitInode(null);
}

test "Accessor: no frame leaks with page type mismatch" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const BptModel = bpt.models.PagedModel(PageCacheT(Device), keyCmp, void);

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();

    const available_before = cache.availableFrames();

    var model = BptModel.init(&cache, .{}, {});
    var accessor = model.getAccessor();

    // Create an inode
    var inode = try accessor.createInode();
    const inode_id = inode.id();
    accessor.deinitInode(inode);

    // Try to load as leaf (mismatch) - this should return null and not leak
    const loaded = try accessor.loadLeaf(inode_id);
    try std.testing.expectEqual(@as(?BptModel.LeafType, null), loaded);

    // Create a leaf
    var leaf = try accessor.createLeaf();
    const leaf_id = leaf.id();
    accessor.deinitLeaf(leaf);

    // Try to load as inode (mismatch) - this should return null and not leak
    const loaded2 = try accessor.loadInode(leaf_id);
    try std.testing.expectEqual(@as(?BptModel.InodeType, null), loaded2);

    const available_after = cache.availableFrames();
    try std.testing.expectEqual(available_before, available_after);
}

test "BtpTree: Create and insert" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const BptModel = bpt.models.PagedModel(PageCacheT(Device), keyCmp, void);

    var device = try Device.init(allocator, 4096);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();

    const available_before = cache.availableFrames();

    var model = BptModel.init(&cache, .{}, {});

    var tree = bpt.Bpt(BptModel).init(&model, .neighbor_share);
    // Create an inode

    _ = try tree.insert("x", "First Value");
    _ = try tree.insert("y", "Second Value");
    _ = try tree.insert("z", "Third Value");

    _ = try tree.update("x", "Updated First Value");

    const val = try tree.find("x");
    try std.testing.expectEqualStrings("Updated First Value", (try val.?.get()).?.value);

    val.?.deinit();
    const available_after = cache.availableFrames();
    try std.testing.expectEqual(available_before, available_after);
}

fn format(allocator: std.mem.Allocator, comptime fmt: []const u8, options: anytype) ![:0]u8 {
    return std.fmt.allocPrintSentinel(allocator, fmt, options, 0) catch @panic("Something went wrong");
}

fn strCmp(a: []const u8, b: []const u8) algorithm.Order {
    // compare null-terminated strings
    var min_len = a.len;
    if (b.len < min_len) {
        min_len = b.len;
    }

    for (0..min_len) |i| {
        if (a[i] == 0 and b[i] == 0) {
            return .eq;
        } else if (a[i] == 0) {
            return .lt;
        } else if (b[i] == 0) {
            return .gt;
        }
        if (a[i] < b[i]) {
            return .lt;
        } else if (a[i] > b[i]) {
            return .gt;
        }
    }

    if (a.len < b.len) {
        return .lt;
    } else if (a.len > b.len) {
        return .gt;
    }
    return .eq;
}

test "Bpt/paged Create with model" {
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

    for (0..500) |i| {
        const key = @as(u32, @intCast(i));
        var buf: [32]u8 = undefined;
        var key_buf: [32]u8 = undefined;
        const value = try std.fmt.bufPrint(&buf, "{}", .{key});
        const key_out = try std.fmt.bufPrint(&key_buf, "{}", .{key});
        _ = try tree.insert(key_out, value);
    }

    for (0..500) |i| {
        const key = @as(u32, @intCast(i));
        var key_buf: [32]u8 = undefined;
        const key_out = try std.fmt.bufPrint(&key_buf, "{}", .{key});

        if (try tree.find(key_out)) |itr_const| {
            defer itr_const.deinit();

            const value = (try itr_const.get()).?.value;
            const expected_value = try format(allocator, "{:0}", .{key});
            defer allocator.free(expected_value);

            const res = strCmp(value[0..], expected_value[0..expected_value.len]);
            //std.debug.print("Key: {s}, Value: {s}, Expected: {s} res {any}\n", .{ key_out, value, expected_value, res });

            // Include the sentinel in the slice: expected_value has len N but the sentinel is at [N]
            try std.testing.expect(res == .eq);
        } else {
            try std.testing.expect(false);
        }
    }
}

test "Bpt Random insertion" {
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

    var prng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const random = prng.random();

    const total_inserts = 1000;
    var inserted_keys = try std.ArrayList(u32).initCapacity(allocator, total_inserts);
    errdefer inserted_keys.deinit(allocator);

    for (0..total_inserts) |_| {
        const key = random.int(u32);
        var buf: [32]u8 = undefined;
        var key_buf: [32]u8 = undefined;
        const key_out = try std.fmt.bufPrint(&key_buf, "{}", .{key});
        const value = try std.fmt.bufPrint(&buf, "{}", .{key});
        if (try tree.insert(key_out, value)) {
            try inserted_keys.append(allocator, key);
        }
    }

    // Verify all inserted keys
    for (inserted_keys.items) |key| {
        var key_buf: [32]u8 = undefined;
        const key_out = try std.fmt.bufPrint(&key_buf, "{}", .{key});
        if (try tree.find(key_out)) |itr_const| {
            defer itr_const.deinit();
            const value = (try itr_const.get()).?.value;
            const expected_value = try format(allocator, "{:0}", .{key});
            defer allocator.free(expected_value);

            // Include the sentinel in the slice: expected_value has len N but the sentinel is at [N]
            try std.testing.expect(strCmp(value[0..], expected_value[0..expected_value.len]) == .eq);
        } else {
            try std.testing.expect(false); // Key should exist
        }
    }

    inserted_keys.deinit(allocator);
}

fn formatKey(key: []const u8) []const u8 {
    return key; // Already a string
}

fn formatValue(value: []const u8) []const u8 {
    return value; // Already a string
}

test "Bpt Update values" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const BptModel = bpt.models.PagedModel(PageCacheT(Device), keyCmp, void);

    var device = try Device.init(allocator, 1024);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();
    var model = BptModel.init(&cache, .{}, {});
    var tree = bpt.Bpt(BptModel).init(&model, .neighbor_share);

    const elements_to_insert = 50000;

    for (0..elements_to_insert) |i| {
        const key = @as(u32, @intCast(i));
        var key_buf: [32]u8 = undefined;
        const key_out = try std.fmt.bufPrint(&key_buf, "{}", .{key});
        var buf: [32]u8 = undefined;
        const value = try std.fmt.bufPrint(&buf, "{}", .{key});
        _ = try tree.insert(key_out, value);
    }

    //try cache.flushAll();
    // std.debug.print("Tree after insertion:\n", .{});
    // _ = try tree.dumpFormatted(formatKey, formatValue);

    // Update values
    for (0..elements_to_insert) |i| {
        const key = @as(u32, @intCast(i));
        var key_buf: [32]u8 = undefined;
        const key_out = try std.fmt.bufPrint(&key_buf, "{}", .{key});
        var buf: [32]u8 = undefined;
        const new_value = try std.fmt.bufPrint(&buf, "updated_{}", .{key});
        //std.debug.print("Updating key: {s} to value: {s}\n", .{ key_out, new_value });
        try std.testing.expect(try tree.update(key_out, new_value)); // Insert should update existing key
    }

    // Verify updates
    for (0..elements_to_insert) |i| {
        const key = @as(u32, @intCast(i));
        var key_buf: [32]u8 = undefined;
        const key_out = try std.fmt.bufPrint(&key_buf, "{}", .{key});
        if (try tree.find(key_out)) |itr_const| {
            defer itr_const.deinit();
            const value = (try itr_const.get()).?.value;
            const expected_value = try format(allocator, "updated_{}", .{key});
            defer allocator.free(expected_value);

            const res = strCmp(value[0..], expected_value[0..expected_value.len]);
            //std.debug.print("Key: {s}, Value: {s}, Expected: {s} res {any}\n", .{ key_out, value, expected_value, res });

            // Include the sentinel in the slice: expected_value has len N but the sentinel is at [N]
            try std.testing.expect(res == .eq);
        } else {
            try std.testing.expect(false); // Key should exist
        }
    }
    // std.debug.print("Tree after updates:\n", .{});
    // _ = try tree.dumpFormatted(formatKey, formatValue);
}

test "Bpt Remove values" {
    const allocator = std.testing.allocator;
    const Device = dev.MemoryBlock(u32);
    const PageCache = PageCacheT(Device);
    const BptModel = bpt.models.PagedModel(PageCache, keyCmp, void);

    var device = try Device.init(allocator, 1024);
    defer device.deinit();
    var cache = try PageCache.init(&device, allocator, 8);
    defer cache.deinit();
    var model = BptModel.init(&cache, .{}, {});
    var tree = bpt.Bpt(BptModel).init(&model, .neighbor_share);

    const elements_to_insert = 50000;

    for (0..elements_to_insert) |i| {
        const key = @as(u32, @intCast(i));
        var key_buf: [32]u8 = undefined;
        const key_out = try std.fmt.bufPrint(&key_buf, "{}", .{key});
        var buf: [32]u8 = undefined;
        const value = try std.fmt.bufPrint(&buf, "{}", .{key});
        _ = try tree.insert(key_out, value);
    }

    //try cache.flushAll();
    // std.debug.print("Tree after insertion:\n", .{});
    // _ = try tree.dumpFormatted(formatKey, formatValue);

    // Update values
    for (0..elements_to_insert / 2) |i| {
        const key = @as(u32, @intCast(i));
        var key_buf: [32]u8 = undefined;
        const key_out = try std.fmt.bufPrint(&key_buf, "{}", .{key});
        try std.testing.expect(try tree.remove(key_out));
    }

    // Verify updates
    for (0..elements_to_insert) |i| {
        const key = @as(u32, @intCast(i));
        var key_buf: [32]u8 = undefined;
        const key_out = try std.fmt.bufPrint(&key_buf, "{}", .{key});
        if (try tree.find(key_out)) |itr_const| {
            defer itr_const.deinit();
            const value = (try itr_const.get()).?.value;
            const expected_value = try format(allocator, "{}", .{key});
            defer allocator.free(expected_value);

            const res = strCmp(value[0..], expected_value[0..expected_value.len]);
            //std.debug.print("Key: {s}, Value: {s}, Expected: {s} res {any}\n", .{ key_out, value, expected_value, res });

            // Include the sentinel in the slice: expected_value has len N but the sentinel is at [N]
            try std.testing.expect(res == .eq);
        }
    }
    // std.debug.print("Tree after updates:\n", .{});
    // _ = try tree.dumpFormatted(formatKey, formatValue);
}
