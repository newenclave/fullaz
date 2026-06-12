const std = @import("std");
const fullaz = @import("fullaz");
const slot_allocator = fullaz.storage.slot_allocator;

const paged_slab = slot_allocator.models.paged_slab;
const SlabModel = paged_slab.Model;

const SlabStorageManagerImpl = struct {
    const Bucket = std.ArrayList(u32);
    buckets: std.ArrayList(Bucket),
};

test "SlotAllocator paged_slab: create the view" {
    const View = paged_slab.View(u32, u16, u16, std.builtin.Endian.little, false).SlabPageView;
    var data = [_]u8{0} ** 1024;
    var view = View.init(&data);
    try view.formatPage(1, 42, 0, 3);

    try std.testing.expectEqual(1, view.page_view.header().kind.get());
    try std.testing.expectEqual(42, view.page_view.header().self_pid.get());
    try std.testing.expectEqual(@sizeOf(View.SubheaderType), view.page_view.header().subheader_size.get());
    try std.testing.expectEqual(0, view.page_view.header().metadata_size.get());

    try std.testing.expectEqual(null, view.getNext());
    try std.testing.expectEqual(null, view.getPrev());

    try view.setNext(1000);
    try view.setPrev(2000);
    try std.testing.expectEqual(1000, view.getNext());
    try std.testing.expectEqual(2000, view.getPrev());
    try std.testing.expectEqual(3, view.sizeClass());

    const s0 = try view.insert(123, 456);
    const s1 = try view.insert(124, 789);
    const s2 = try view.insert(125, 1024);

    _ = s2;

    const p1 = try view.findByPid(123);
    try std.testing.expectEqual(p1, s0);

    const ps2 = try view.findBySize(700);
    try std.testing.expectEqual(ps2, s1);
}
