const std = @import("std");
const testing = std.testing;

const page = @import("fullaz").page;
const header = page.header;

const algorithm = @import("fullaz").algorithm;

// =============================================================================
// Header View Tests
// =============================================================================

test "Header.View: init creates valid view" {
    var buffer: [256]u8 = undefined;
    @memset(&buffer, 0);

    const HeaderView = header.View(u32, u16, .little, false);
    const view = HeaderView.init(&buffer);

    _ = view.header();
}

test "Header.View: formatPage sets header fields correctly" {
    var buffer: [256]u8 = undefined;
    @memset(&buffer, 0);

    const HeaderView = header.View(u32, u16, .little, false);
    var view = HeaderView.init(&buffer);

    view.formatPage(42, 123, 8, 16); // kind=42, page_id=123, subhdr_len=8, metadata_len=16

    const hdr = view.header();
    try testing.expectEqual(@as(u16, 42), hdr.kind.get());
    try testing.expectEqual(@as(u32, 123), hdr.self_pid.get());
    try testing.expectEqual(@as(u16, 8), hdr.subheader_size.get());
    try testing.expectEqual(@as(u16, 16), hdr.metadata_size.get());
    try testing.expectEqual(@as(u16, 256), hdr.page_end.get());
}

test "Header.View: subheader returns correct slice" {
    var buffer: [256]u8 = undefined;
    @memset(&buffer, 0);

    const HeaderView = header.View(u32, u16, .little, false);
    var view = HeaderView.init(&buffer);

    view.formatPage(1, 0, 8, 0);

    const subhdr = view.subheader();
    try testing.expectEqual(@as(usize, 8), subhdr.len);
}

test "Header.View: subheaderMut allows modification" {
    var buffer: [256]u8 = undefined;
    @memset(&buffer, 0);

    const HeaderView = header.View(u32, u16, .little, false);
    var view = HeaderView.init(&buffer);

    view.formatPage(1, 0, 8, 0);

    const subhdr = view.subheaderMut();
    subhdr[0] = 0xAB;
    subhdr[7] = 0xCD;

    const subhdr_read = view.subheader();
    try testing.expectEqual(@as(u8, 0xAB), subhdr_read[0]);
    try testing.expectEqual(@as(u8, 0xCD), subhdr_read[7]);
}

test "Header.View: metadata returns correct slice" {
    var buffer: [256]u8 = undefined;
    @memset(&buffer, 0);

    const HeaderView = header.View(u32, u16, .little, false);
    var view = HeaderView.init(&buffer);

    view.formatPage(1, 0, 8, 16);

    const meta = view.metadata();
    try testing.expectEqual(@as(usize, 16), meta.len);
}

test "Header.View: metadataMut allows modification" {
    var buffer: [256]u8 = undefined;
    @memset(&buffer, 0);

    const HeaderView = header.View(u32, u16, .little, false);
    var view = HeaderView.init(&buffer);

    view.formatPage(1, 0, 8, 16);

    const meta = view.metadataMut();
    meta[0] = 0x11;
    meta[15] = 0x22;

    const meta_read = view.metadata();
    try testing.expectEqual(@as(u8, 0x11), meta_read[0]);
    try testing.expectEqual(@as(u8, 0x22), meta_read[15]);
}

test "Header.View: data returns slice after all headers" {
    var buffer: [256]u8 = undefined;
    @memset(&buffer, 0);

    const HeaderView = header.View(u32, u16, .little, false);
    var view = HeaderView.init(&buffer);

    view.formatPage(1, 0, 8, 16);

    const hdr_size = HeaderView.pageHeaderSize();
    const all_headers = view.allHeadersSize();
    try testing.expectEqual(hdr_size + 8 + 16, all_headers);

    const data_slice = view.data();
    try testing.expectEqual(@as(usize, 256 - all_headers), data_slice.len);
}

test "Header.View: big endian format" {
    var buffer: [256]u8 = undefined;
    @memset(&buffer, 0);

    const HeaderView = header.View(u32, u16, .big, false);
    var view = HeaderView.init(&buffer);

    view.formatPage(0x1234, 0xDEADBEEF, 8, 16);

    const hdr = view.header();
    try testing.expectEqual(@as(u16, 0x1234), hdr.kind.get());
    try testing.expectEqual(@as(u32, 0xDEADBEEF), hdr.self_pid.get());
}

test "Header.View: read-only view prevents mutation at comptime" {
    var buffer: [256]u8 = undefined;
    @memset(&buffer, 0);

    const HeaderViewMut = header.View(u32, u16, .little, false);
    var view_mut = HeaderViewMut.init(&buffer);
    view_mut.formatPage(1, 0, 8, 16);

    // Create read-only view
    const HeaderViewRO = header.View(u32, u16, .little, true);
    const view_ro = HeaderViewRO.init(&buffer);

    // Can read
    const hdr = view_ro.header();
    try testing.expectEqual(@as(u16, 1), hdr.kind.get());

    // These would fail at comptime if uncommented:
    // _ = view_ro.headerMut();
    // _ = view_ro.subheaderMut();
    // _ = view_ro.metadataMut();
    // _ = view_ro.dataMut();
}

// =============================================================================
// Freed Page Tests
// =============================================================================

test "Freed.View: formatPage sets fields correctly" {
    var buffer: [64]u8 = undefined;
    @memset(&buffer, 0);

    const FreedView = page.freed.View(u32, .little, false);
    var view = FreedView.init(&buffer);

    view.formatPage(42); // next_page_id = 42

    const hdr = view.header();
    // kind should be set to max u16 value (0xFFFF) to mark as freed
    try testing.expectEqual(@as(u16, 0xFFFF), hdr.kind.get());
    try testing.expectEqual(@as(u32, 42), hdr.next.get());
    try testing.expectEqual(@as(u32, 0), hdr.crc.get());
}

test "Freed.View: headerMut allows modification" {
    var buffer: [64]u8 = undefined;
    @memset(&buffer, 0);

    const FreedView = page.freed.View(u32, .little, false);
    var view = FreedView.init(&buffer);

    view.formatPage(0);

    const hdr = view.headerMut();
    hdr.next.set(999);

    try testing.expectEqual(@as(u32, 999), view.header().next.get());
}

test "Freed.View: big endian format" {
    var buffer: [64]u8 = undefined;
    @memset(&buffer, 0);

    const FreedView = page.freed.View(u32, .big, false);
    var view = FreedView.init(&buffer);

    view.formatPage(0x12345678);

    const hdr = view.header();
    try testing.expectEqual(@as(u32, 0x12345678), hdr.next.get());
}

// =============================================================================
// Subheader View Tests
// =============================================================================

test "Subheader.View: typed subheader access" {
    var buffer: [256]u8 = undefined;
    @memset(&buffer, 0);

    const TestSubheader = extern struct {
        magic: u32,
        count: u16,
        flags: u16,
    };

    const SubheaderView = page.subheader.View(u32, u16, TestSubheader, .little, false);
    var view = SubheaderView.init(&buffer);

    view.formatPage(100, 1, 0); // kind=100, page_id=1, metadata_len=0

    const subhdr = view.subheaderMut();
    subhdr.magic = 0xCAFEBABE;
    subhdr.count = 42;
    subhdr.flags = 0x0001;

    const subhdr_read = view.subheader();
    try testing.expectEqual(@as(u32, 0xCAFEBABE), subhdr_read.magic);
    try testing.expectEqual(@as(u16, 42), subhdr_read.count);
    try testing.expectEqual(@as(u16, 0x0001), subhdr_read.flags);
}

test "Page/bpt module: contains expected types" {
    const Bpt = page.bpt.Bpt(u32, u16, .little, false);

    _ = Bpt.PageViewType;
    _ = Bpt.LeafSubheader;
    _ = Bpt.InodeSubheader;
    _ = Bpt.LeafSubheaderView;
    _ = Bpt.InodeSubheaderView;
    _ = Bpt.InodeSlotHeader;
    _ = Bpt.LeafSlotHeader;
}

test "page/bpt create pages with differernt sunbeaders" {
    var leaf_buffer: [1024]u8 = undefined;
    var inode_buffer: [1024]u8 = undefined;
    @memset(&leaf_buffer, 0);
    @memset(&inode_buffer, 0);
    const Bpt = page.bpt.Bpt(u32, u16, .little, false);

    var leaf_view = Bpt.LeafSubheaderView.init(&leaf_buffer);
    try leaf_view.formatPage(1, 2, 0);

    leaf_view.subheaderMut().formatHeader();

    var inode_view = Bpt.InodeSubheaderView.init(&inode_buffer);
    try inode_view.formatPage(2, 4, 0);

    try testing.expect(leaf_view.subheader().next.get() == @as(u32, 0xFFFFFFFF));
    try testing.expect(leaf_view.subheader().prev.get() == @as(u32, 0xFFFFFFFF));
    try testing.expect(leaf_view.subheader().parent.get() == @as(u32, 0xFFFFFFFF));

    const res_leaf_sh = leaf_view.page_view.subheader().len;
    const res_inode_sh = inode_view.page_view.subheader().len;
    const real_leaf_size: usize = @sizeOf(Bpt.LeafSubheader);
    const real_inode_size: usize = @sizeOf(Bpt.InodeSubheader);

    try testing.expect(res_leaf_sh == real_leaf_size);
    try testing.expect(res_inode_sh == real_inode_size);

    try testing.expect(leaf_view.page_view.header().kind.get() == 1);
    try testing.expect(inode_view.page_view.header().kind.get() == 2);
}

fn randomString(
    allocator: std.mem.Allocator,
    rnd: std.Random,
    len: usize,
) ![]u8 {
    const charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

    const buf = try allocator.alloc(u8, len);

    for (buf) |*c| {
        const idx = rnd.intRangeLessThan(usize, 0, charset.len);
        c.* = charset[idx];
    }

    return buf;
}

fn SlotInserter(comptime BptHeader: type) type {
    const Slots = BptHeader.Slots;
    const SlotEntry = BptHeader.LeafSlotHeader;
    const Entry = Slots.Entry;

    return struct {
        const Self = @This();
        slot_dir: Slots,

        pub fn init(slot_dir: Slots) Self {
            return .{
                .slot_dir = slot_dir,
            };
        }

        pub fn insertSlot(self: *Self, index: usize, key: []const u8, value: []const u8) !void {
            const total_size: usize = @sizeOf(SlotEntry) + key.len + value.len;
            var buffer = try self.slot_dir.reserveGet(index, total_size);
            var slot: *SlotEntry = @ptrCast(&buffer[0]);

            slot.key_size.set(@as(@TypeOf(slot.key_size.get()), @intCast(key.len)));

            const key_dst = buffer[@sizeOf(SlotEntry)..][0..key.len];
            @memcpy(key_dst, key);

            const value_dst = buffer[@sizeOf(SlotEntry) + key.len ..][0..value.len];
            @memcpy(value_dst, value);
        }

        const KeyValue = struct {
            key: []const u8,
            value: []const u8,
        };

        fn keyValueFromBuffer(buffer: []const u8) !KeyValue {
            const slot: *const SlotEntry = @ptrCast(&buffer[0]);
            const key_size = @as(usize, slot.key_size.get());
            const key_offset = @sizeOf(SlotEntry);
            const value_offset = key_offset + key_size;

            return .{
                .key = buffer[key_offset .. key_offset + key_size],
                .value = buffer[value_offset..],
            };
        }

        pub fn getSlot(self: *const Self, index: usize) !KeyValue {
            const buffer = try self.slot_dir.get(index);
            return keyValueFromBuffer(buffer);
        }

        fn slotLess(ctx: *const Slots, a: Entry, key: []const u8) algorithm.Order {
            const slot_key = ctx.getByEntry(&a) catch return .gt;

            const slot_values = try keyValueFromBuffer(slot_key);

            return algorithm.cmpSlices(u8, slot_values.key, key, algorithm.CmpNum(u8).desc, void);
        }

        pub fn lowerBound(self: *const Self, key: []const u8) !usize {
            return try algorithm.lowerBound(Entry, self.slot_dir.entriesConst(), key, slotLess, &self.slot_dir);
        }
    };
}

test "page/bpt slots compare and proj" {
    var leaf_buffer: [1024]u8 = undefined;
    @memset(&leaf_buffer, 0);
    const Bpt = page.bpt.Bpt(u32, u16, .little, false);
    var leaf_view = Bpt.LeafSubheaderView.init(&leaf_buffer);
    try leaf_view.formatPage(1, 2, 0);
    leaf_view.subheaderMut().formatHeader();

    var inserter = SlotInserter(Bpt).init(try leaf_view.slotsDir());

    var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const rnd = prng.random();

    for (0..10) |_| {
        const value = try randomString(std.testing.allocator, rnd, 10);
        defer std.testing.allocator.free(value);

        const key = try randomString(std.testing.allocator, rnd, 8);
        defer std.testing.allocator.free(key);

        const pos = try inserter.lowerBound(key);
        try inserter.insertSlot(pos, key, value);
    }

    for (0..10) |i| {
        const slot = try inserter.getSlot(i);
        std.debug.print("Slot {d}: key='{s}', value='{s}'\n", .{ i, slot.key, slot.value });
        // Just verify that we can read the keys and values back
        try testing.expect(slot.key.len == 8);
        try testing.expect(slot.value.len == 10);
    }
}
