const std = @import("std");
const testing = std.testing;

const page = @import("fullaz").page;
const bpt_view = @import("fullaz").bpt.models.paged;
const header = page.header;
const extensions = page.extensions;
const PackedInt = @import("fullaz").core.packed_int.PackedInt;
const FsmLocationTrait = @import("fullaz").storage.fsm.location.Trait(u32, u16, .little);
const PageLinksTrait = page.links.Trait(u32, .little);

const algorithm = @import("fullaz").core.algorithm;

const HeaderFsmTrait = struct {
    pub const Storage = extern struct {
        page_id: PackedInt(u32, .little),
        slot_id: PackedInt(u16, .little),
    };

    pub fn format(storage: *Storage) void {
        storage.page_id.setMax();
        storage.slot_id.setMax();
    }

    pub fn validate(storage: *const Storage) bool {
        return storage.page_id.isMax() == storage.slot_id.isMax();
    }
};

fn headerAdditional(comptime version: u8) type {
    return extensions.Compose(.{
        .version = version,
        .fields = .{
            extensions.field("fsm", HeaderFsmTrait),
        },
    });
}

fn getRandomSeed() !u64 {
    const io = std.testing.io;
    var seed: u64 = undefined;
    std.Io.random(io, std.mem.asBytes(&seed));
    return seed;
}

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

test "Header.View: additional field" {
    var buffer: [256]u8 = undefined;
    @memset(&buffer, 0);

    const Additional = headerAdditional(2);

    const HeaderView = header.ViewImpl(u32, u16, Additional, .little, false);
    var view = HeaderView.init(&buffer);
    view.formatPage(42, 123, 8, 16); // kind=42, page_id=123, subhdr_len=8, metadata_len=16
    //const hdr = view.header();
    //const add = view.additional();
    //std.debug.print("Add non void ptr = {any}\n", .{add});

    try testing.expect(HeaderView.header_size - HeaderView.common_size == @sizeOf(Additional.Storage));
}

test "Header.View: common reader uses stored extended header size" {
    const Additional = headerAdditional(7);
    const ExtendedView = header.ViewImpl(u32, u16, Additional, .little, false);
    const CommonView = header.View(u32, u16, .little, true);

    var buffer: [256]u8 = undefined;
    @memset(&buffer, 0);

    var extended = ExtendedView.init(&buffer);
    extended.formatPage(42, 123, 8, 16);
    try testing.expect(Additional.validate(extended.additional()));
    Additional.fieldMut(extended.additionalMut(), "fsm").page_id.set(77);
    Additional.fieldMut(extended.additionalMut(), "fsm").slot_id.set(3);

    const subheader = extended.subheaderMut();
    subheader[0] = 0xAA;
    subheader[7] = 0xBB;
    const metadata = extended.metadataMut();
    metadata[0] = 0xCC;
    metadata[15] = 0xDD;

    const common = CommonView.init(&buffer);
    try testing.expectEqual(@as(u8, 7), common.header().version.get());
    try testing.expectEqual(@as(u8, @intCast(ExtendedView.header_size)), common.headerSize());
    try testing.expectEqual(ExtendedView.header_size, common.headerSize());
    try testing.expectEqualSlices(u8, &.{ 0xAA, 0, 0, 0, 0, 0, 0, 0xBB }, common.subheader());
    try testing.expectEqual(@as(usize, 16), common.metadata().len);
    try testing.expectEqual(@as(u8, 0xCC), common.metadata()[0]);
    try testing.expectEqual(@as(u8, 0xDD), common.metadata()[15]);
    try testing.expectEqual(@as(usize, 256 - ExtendedView.header_size - 8 - 16), common.data().len);
}

test "Header.View: composed FSM location and page links remain independent" {
    const Additional = extensions.Compose(.{
        .version = 9,
        .fields = .{
            extensions.field("fsm", FsmLocationTrait),
            extensions.field("links", PageLinksTrait),
        },
    });
    const ExtendedView = header.ViewImpl(u32, u16, Additional, .little, false);

    var buffer: [256]u8 = undefined;
    @memset(&buffer, 0);

    var view = ExtendedView.init(&buffer);
    view.formatPage(42, 123, 8, 16);

    const fsm = Additional.fieldMut(view.additionalMut(), "fsm");
    const links = Additional.fieldMut(view.additionalMut(), "links");
    try testing.expectEqual(@as(?FsmLocationTrait.Location, null), FsmLocationTrait.get(fsm));
    try testing.expectEqual(@as(?u32, null), PageLinksTrait.getPrev(links));
    try testing.expectEqual(@as(?u32, null), PageLinksTrait.getNext(links));

    FsmLocationTrait.set(fsm, .{ .page_id = 77, .slot_id = 3 });
    PageLinksTrait.setPrev(links, 11);
    PageLinksTrait.setNext(links, 22);

    const location = FsmLocationTrait.get(Additional.field(view.additional(), "fsm")).?;
    try testing.expectEqual(@as(u32, 77), location.page_id);
    try testing.expectEqual(@as(u16, 3), location.slot_id);
    try testing.expectEqual(
        @as(?u32, 11),
        PageLinksTrait.getPrev(Additional.field(view.additional(), "links")),
    );
    try testing.expectEqual(
        @as(?u32, 22),
        PageLinksTrait.getNext(Additional.field(view.additional(), "links")),
    );

    FsmLocationTrait.clear(fsm);
    try testing.expectEqual(
        @as(?FsmLocationTrait.Location, null),
        FsmLocationTrait.get(Additional.field(view.additional(), "fsm")),
    );
    try testing.expectEqual(
        @as(?u32, 11),
        PageLinksTrait.getPrev(Additional.field(view.additional(), "links")),
    );
    try testing.expectEqual(
        @as(?u32, 22),
        PageLinksTrait.getNext(Additional.field(view.additional(), "links")),
    );
}

test "Header.View: validates common and typed layouts" {
    const Additional = headerAdditional(7);
    const ExtendedView = header.ViewImpl(u32, u16, Additional, .little, false);
    const CommonView = header.View(u32, u16, .little, true);
    const WrongVersionView = header.ViewImpl(u32, u16, headerAdditional(8), .little, true);

    var buffer: [256]u8 = undefined;
    @memset(&buffer, 0);

    var extended = ExtendedView.init(&buffer);
    extended.formatPage(42, 123, 8, 16);
    try extended.validateCommon();
    try extended.validateTyped();

    const common = CommonView.init(&buffer);
    try common.validateCommon();
    try testing.expectError(CommonView.Error.InvalidHeaderSize, common.validateTyped());

    const wrong_version = WrongVersionView.init(&buffer);
    try testing.expectError(WrongVersionView.Error.UnsupportedVersion, wrong_version.validateTyped());
}

test "Header.View: common validation rejects corrupted layout" {
    const HeaderView = header.View(u32, u16, .little, false);

    var buffer: [256]u8 = undefined;
    @memset(&buffer, 0);

    var view = HeaderView.init(&buffer);
    view.formatPage(42, 123, 8, 16);

    view.headerMut().header_size.set(0);
    try testing.expectError(HeaderView.Error.InvalidHeaderSize, view.validateCommon());

    view.headerMut().header_size.set(@intCast(HeaderView.header_size));
    view.headerMut().page_end.set(128);
    try testing.expectError(HeaderView.Error.InvalidPageEnd, view.validateCommon());

    view.headerMut().page_end.set(256);
    view.headerMut().metadata_size.set(250);
    try testing.expectError(HeaderView.Error.InconsistentLayout, view.validateCommon());
}

test "Header.HeaderImpl keeps version and header size types distinct" {
    const HeaderT = header.HeaderImpl(u32, u16, u16, u8, void, .little);

    comptime {
        if (@TypeOf(@as(HeaderT, undefined).version) != PackedInt(u8, .little)) {
            @compileError("version must use VersionT");
        }
        if (@TypeOf(@as(HeaderT, undefined).header_size) != PackedInt(u16, .little)) {
            @compileError("header_size must use HeaderSizeT");
        }
    }
}

test "Header.View: void field" {
    var buffer: [256]u8 = undefined;
    @memset(&buffer, 0);

    const HeaderView = header.View(u32, u16, .little, false);
    var view = HeaderView.init(&buffer);
    view.formatPage(42, 123, 8, 16); // kind=42, page_id=123, subhdr_len=8, metadata_len=16
    //const hdr = view.header();
    //const add = view.additional();
    //std.debug.print("Add void ptr = {any}\n", .{add});

    try testing.expectEqual(@as(u8, 1), view.header().version.get());
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
    try testing.expectEqual(@as(u8, 1), hdr.version.get());
    try testing.expectEqual(@as(u8, @intCast(HeaderView.header_size)), view.headerSize());
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

    const hdr_size = HeaderView.header_size;
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
        magic: [4]u8,
        count: [2]u8,
        flags: [2]u8,
    };

    const SubheaderView = page.subheader.View(u32, u16, TestSubheader, .little, false);
    var view = SubheaderView.init(&buffer);

    view.formatPage(100, 1, 0); // kind=100, page_id=1, metadata_len=0

    const subhdr = view.subheaderMut();
    subhdr.magic = [_]u8{ 0xCA, 0xFE, 0xBA, 0xBE };
    subhdr.count = [_]u8{ 0x00, 0x2A };
    subhdr.flags = [_]u8{ 0x00, 0x01 };

    const subhdr_read = view.subheader();
    try testing.expectEqual([_]u8{ 0xCA, 0xFE, 0xBA, 0xBE }, subhdr_read.magic);
    try testing.expectEqual([_]u8{ 0x00, 0x2A }, subhdr_read.count);
    try testing.expectEqual([_]u8{ 0x00, 0x01 }, subhdr_read.flags);
}

test "Page/bpt module: contains expected types" {
    const Bpt = page.bpt.Bpt(u32, u16, .little);

    _ = Bpt.LeafSubheader;
    _ = Bpt.InodeSubheader;
    _ = Bpt.InodeSlotHeader;
    _ = Bpt.LeafSlotHeader;
}

test "page/bpt create pages with differernt sunbeaders" {
    var leaf_buffer: [1024]u8 = undefined;
    var inode_buffer: [1024]u8 = undefined;
    @memset(&leaf_buffer, 0);
    @memset(&inode_buffer, 0);
    const Bpt = bpt_view.View(u32, u16, .little, false);

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

const MyCmp = struct {
    pub fn cmp(_: void, a: []const u8, b: []const u8) !algorithm.Order {
        return try algorithm.cmpSlices(u8, a, b, algorithm.CmpNum(u8).asc, {});
    }
};

test "page/bpt slots compare and proj" {
    var leaf_buffer: [1024]u8 = undefined;
    @memset(&leaf_buffer, 0);
    const Bpt = bpt_view.View(u32, u16, .little, false);
    var leaf_view = Bpt.LeafSubheaderView.init(&leaf_buffer);
    try leaf_view.formatPage(1, 2, 0);
    leaf_view.subheaderMut().formatHeader();

    var prng = std.Random.DefaultPrng.init(try getRandomSeed());
    const rnd = prng.random();

    for (0..10) |_| {
        const value = try randomString(std.testing.allocator, rnd, 10);
        defer std.testing.allocator.free(value);

        const key = try randomString(std.testing.allocator, rnd, 8);
        defer std.testing.allocator.free(key);

        const pos = try leaf_view.lowerBoundWith(key, MyCmp.cmp, {});
        try testing.expect(try leaf_view.canInsert(pos, key, value) != .not_enough);
        if (pos > 0) {
            try testing.expect(try leaf_view.canUpdate(0, key, value) != .not_enough);
        }
        try leaf_view.insert(pos, key, value);
    }

    // for (0..10) |i| {
    //     const slot = try leaf_view.get(i);
    //     std.debug.print("Slot {d}: key='{s}', value='{s}'\n", .{ i, slot.key, slot.value });
    //     // Just verify that we can read the keys and values back
    //     try testing.expect(slot.key.len == 8);
    //     try testing.expect(slot.value.len == 10);
    // }
}

test "page/bpt slots compare and proj inodes" {
    var leaf_buffer: [1024]u8 = undefined;
    @memset(&leaf_buffer, 0);
    const Bpt = bpt_view.View(u32, u16, .little, false);
    var inode_view = Bpt.InodeSubheaderView.init(&leaf_buffer);
    try inode_view.formatPage(1, 2, 0);

    var prng = std.Random.DefaultPrng.init(try getRandomSeed());
    const rnd = prng.random();

    for (0..10) |i| {
        const value = try randomString(std.testing.allocator, rnd, 10);
        defer std.testing.allocator.free(value);

        const key = try randomString(std.testing.allocator, rnd, 8);
        defer std.testing.allocator.free(key);

        const pos = try inode_view.upperBoundWith(key, MyCmp.cmp, {});
        try testing.expect(try inode_view.canInsert(pos, key, @as(u32, @intCast(i))) != .not_enough);
        if (i > 0) {
            try testing.expect(try inode_view.canUpdate(0, key) != .not_enough);
        }
        try inode_view.insert(pos, key, @as(u32, @intCast(i)));
    }

    // for (0..10) |i| {
    //     const slot = try inode_view.get(i);
    //     std.debug.print("Slot {d}: key='{s}', child='{}'\n", .{ i, slot.key, slot.child });
    //     // Just verify that we can read the keys and values back
    //     try testing.expect(slot.key.len == 8);
    // }
}
