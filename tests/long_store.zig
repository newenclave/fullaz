const std = @import("std");
const long_store = @import("fullaz").storage.long_store;

test "LongStore Create a header view" {
    const HeaderViewType = long_store.View(u32, u32, u32, std.builtin.Endian.little, false).HeaderView;
    var buffer: [1024]u8 = undefined;
    var view = HeaderViewType.init(buffer[0..]);

    view.formatPage(1, 42, 0);

    const sh = view.subheader();
    try std.testing.expect(sh.total_size.get() == 0);
    try std.testing.expect(sh.last.get() == @TypeOf(sh.last).max());
    try std.testing.expect(sh.next.get() == @TypeOf(sh.next).max());
    try std.testing.expect(sh.data.size.get() == 0);
    try std.testing.expect(sh.data.reserved.get() == 0);
    const data = view.data();
    try std.testing.expect(data.len == (1024 - view.pageView().allHeadersSize()));
    const dataMut = view.dataMut();
    try std.testing.expect(dataMut.len == (1024 - view.pageView().allHeadersSize()));
}

test "LongStore Create a Chunk view" {
    const ChunkViewType = long_store.View(u32, u32, u32, std.builtin.Endian.little, false).ChunkView;
    var buffer: [1024]u8 = undefined;
    var view = ChunkViewType.init(buffer[0..]);

    view.formatPage(1, 42, 0);

    const sh = view.subheader();
    try std.testing.expect(sh.prev.get() == @TypeOf(sh.prev).max());
    try std.testing.expect(sh.next.get() == @TypeOf(sh.next).max());
    try std.testing.expect(sh.data.size.get() == 0);
    try std.testing.expect(sh.data.reserved.get() == 0);
}

test "HeaderView getNext/setNext" {
    const HeaderViewType = long_store.View(u32, u32, u32, std.builtin.Endian.little, false).HeaderView;
    var buffer: [1024]u8 = undefined;
    var view = HeaderViewType.init(buffer[0..]);
    view.formatPage(1, 42, 0);

    // Test null next
    try std.testing.expect(view.getNext() == null);

    // Test set next
    view.setNext(100);
    try std.testing.expect(view.getNext() == 100);

    // Test set next to null
    view.setNext(null);
    try std.testing.expect(view.getNext() == null);
}

test "HeaderView getLast/setLast" {
    const HeaderViewType = long_store.View(u32, u32, u32, std.builtin.Endian.little, false).HeaderView;
    var buffer: [1024]u8 = undefined;
    var view = HeaderViewType.init(buffer[0..]);
    view.formatPage(1, 42, 0);

    // Test null last
    try std.testing.expect(view.getLast() == null);

    // Test set last
    view.setLast(200);
    try std.testing.expect(view.getLast() == 200);

    // Test set last to null
    view.setLast(null);
    try std.testing.expect(view.getLast() == null);
}

test "HeaderView getTotalSize/setTotalSize" {
    const HeaderViewType = long_store.View(u32, u32, u32, std.builtin.Endian.little, false).HeaderView;
    var buffer: [1024]u8 = undefined;
    var view = HeaderViewType.init(buffer[0..]);
    view.formatPage(1, 42, 0);

    // Test initial total size is 0
    try std.testing.expect(view.getTotalSize() == 0);

    // Test set total size
    view.setTotalSize(500);
    try std.testing.expect(view.getTotalSize() == 500);
}

test "HeaderView incrementTotalSize/decrementTotalSize" {
    const HeaderViewType = long_store.View(u32, u32, u32, std.builtin.Endian.little, false).HeaderView;
    var buffer: [1024]u8 = undefined;
    var view = HeaderViewType.init(buffer[0..]);
    view.formatPage(1, 42, 0);

    view.setTotalSize(100);
    view.incrementTotalSize(50);
    try std.testing.expect(view.getTotalSize() == 150);

    view.decrementTotalSize(30);
    try std.testing.expect(view.getTotalSize() == 120);
}

test "HeaderView getDataSize/setDataSize" {
    const HeaderViewType = long_store.View(u32, u32, u32, std.builtin.Endian.little, false).HeaderView;
    var buffer: [1024]u8 = undefined;
    var view = HeaderViewType.init(buffer[0..]);
    view.formatPage(1, 42, 0);

    // Test initial data size is 0
    try std.testing.expect(view.getDataSize() == 0);

    // Test set data size
    view.setDataSize(256);
    try std.testing.expect(view.getDataSize() == 256);
}

test "HeaderView incrementDataSize/decrementDataSize" {
    const HeaderViewType = long_store.View(u32, u32, u32, std.builtin.Endian.little, false).HeaderView;
    var buffer: [1024]u8 = undefined;
    var view = HeaderViewType.init(buffer[0..]);
    view.formatPage(1, 42, 0);

    view.setDataSize(100);
    view.incrementDataSize(25);
    try std.testing.expect(view.getDataSize() == 125);

    view.decrementDataSize(15);
    try std.testing.expect(view.getDataSize() == 110);
}

test "ChunkView getNext/setNext" {
    const ChunkViewType = long_store.View(u32, u32, u32, std.builtin.Endian.little, false).ChunkView;
    var buffer: [1024]u8 = undefined;
    var view = ChunkViewType.init(buffer[0..]);
    view.formatPage(1, 42, 0);

    // Test null next
    try std.testing.expect(view.getNext() == null);

    // Test set next
    view.setNext(150);
    try std.testing.expect(view.getNext() == 150);

    // Test set next to null
    view.setNext(null);
    try std.testing.expect(view.getNext() == null);
}

test "ChunkView getPrev/setPrev" {
    const ChunkViewType = long_store.View(u32, u32, u32, std.builtin.Endian.little, false).ChunkView;
    var buffer: [1024]u8 = undefined;
    var view = ChunkViewType.init(buffer[0..]);
    view.formatPage(1, 42, 0);

    // Test null prev
    try std.testing.expect(view.getPrev() == null);

    // Test set prev
    view.setPrev(99);
    try std.testing.expect(view.getPrev() == 99);

    // Test set prev to null
    view.setPrev(null);
    try std.testing.expect(view.getPrev() == null);
}

test "ChunkView getDataSize/setDataSize" {
    const ChunkViewType = long_store.View(u32, u32, u32, std.builtin.Endian.little, false).ChunkView;
    var buffer: [1024]u8 = undefined;
    var view = ChunkViewType.init(buffer[0..]);
    view.formatPage(1, 42, 0);

    // Test initial data size is 0
    try std.testing.expect(view.getDataSize() == 0);

    // Test set data size
    view.setDataSize(512);
    try std.testing.expect(view.getDataSize() == 512);
}

test "ChunkView incrementDataSize/decrementDataSize" {
    const ChunkViewType = long_store.View(u32, u32, u32, std.builtin.Endian.little, false).ChunkView;
    var buffer: [1024]u8 = undefined;
    var view = ChunkViewType.init(buffer[0..]);
    view.formatPage(1, 42, 0);

    view.setDataSize(100);
    view.incrementDataSize(40);
    try std.testing.expect(view.getDataSize() == 140);

    view.decrementDataSize(20);
    try std.testing.expect(view.getDataSize() == 120);
}

test "ChunkView hasFlag/setFlag/clearFlag" {
    const ChunkViewType = long_store.View(u32, u32, u32, std.builtin.Endian.little, false).ChunkView;
    var buffer: [1024]u8 = undefined;
    var view = ChunkViewType.init(buffer[0..]);
    view.formatPage(1, 42, 0);

    // Test flag not set initially
    try std.testing.expect(!view.hasFlag(ChunkViewType.Flags.first));

    // Test set flag
    view.setFlag(ChunkViewType.Flags.first);
    try std.testing.expect(view.hasFlag(.first));

    // Test clear flag
    view.clearFlag(ChunkViewType.Flags.first);
    try std.testing.expect(!view.hasFlag(.first));
}
