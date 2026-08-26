const std = @import("std");
const fullaz = @import("fullaz");

const Store = struct {
    pub const PageId = usize;
    pub const Error = error{InvalidPageId};

    pub const Page = struct {
        kind_value: u16,
        bytes: []const u8,
    };

    const Entry = struct {
        kind_value: u16,
        bytes: []const u8,
        free: bool = false,
        reserved: bool = false,
    };

    entries: []Entry,

    pub fn pageCount(self: *const @This()) usize {
        return self.entries.len;
    }

    pub fn isFree(self: *const @This(), page_id: usize) Error!bool {
        if (page_id >= self.entries.len) {
            return error.InvalidPageId;
        }
        return self.entries[page_id].free;
    }

    pub fn fetchPage(self: *const @This(), page_id: usize) Error!Page {
        if (page_id >= self.entries.len or self.entries[page_id].free) {
            return error.InvalidPageId;
        }
        return .{
            .kind_value = self.entries[page_id].kind_value,
            .bytes = self.entries[page_id].bytes,
        };
    }

    pub fn releasePage(_: *const @This(), _: *Page) void {}

    pub fn pageKind(_: *const @This(), page: *const Page, _: usize) Error!u16 {
        return page.kind_value;
    }

    pub fn pageData(_: *const @This(), page: *const Page) Error![]const u8 {
        return page.bytes;
    }

    pub fn isReserved(self: *const @This(), page_id: usize) Error!bool {
        if (page_id >= self.entries.len) {
            return error.InvalidPageId;
        }
        return self.entries[page_id].reserved;
    }

    pub fn reclaim(self: *@This(), page_id: usize) Error!void {
        if (page_id >= self.entries.len or self.entries[page_id].reserved) {
            return error.InvalidPageId;
        }
        self.entries[page_id].free = true;
    }
};

test "GC: memory model marks roots and sweeps only unreachable pages" {
    const Model = fullaz.gc.models.Memory(Store);
    const Collector = fullaz.gc.Gc(Model);
    const ScannerFixture = struct {
        fn branch(
            _: ?*const anyopaque,
            _: usize,
            page: []const u8,
            sink: Collector.ReferenceSink,
        ) Collector.Error!void {
            for (page) |child| {
                try sink.visit(child);
            }
        }

        fn leaf(
            _: ?*const anyopaque,
            _: usize,
            _: []const u8,
            _: Collector.ReferenceSink,
        ) Collector.Error!void {}
    };

    var entries = [_]Store.Entry{
        .{ .kind_value = 0, .bytes = &.{}, .reserved = true },
        .{ .kind_value = 1, .bytes = &.{ 2, 3 } },
        .{ .kind_value = 1, .bytes = &.{4} },
        .{ .kind_value = 2, .bytes = &.{} },
        .{ .kind_value = 2, .bytes = &.{} },
        .{ .kind_value = 2, .bytes = &.{} },
        .{ .kind_value = 2, .bytes = &.{}, .free = true },
    };
    var store = Store{ .entries = &entries };
    var model = Model.init(std.testing.allocator, &store);
    defer model.deinit();
    var gc = Collector.init(&model);
    defer gc.deinit();
    try gc.register(1, 1, null, ScannerFixture.branch, null);
    try gc.register(2, 1, null, ScannerFixture.leaf, null);
    try gc.start(&.{1});

    while (try gc.step(1) != .complete) {}

    try std.testing.expect(!entries[1].free);
    try std.testing.expect(!entries[2].free);
    try std.testing.expect(!entries[3].free);
    try std.testing.expect(!entries[4].free);
    try std.testing.expect(entries[5].free);
    try std.testing.expect(entries[6].free);
    try std.testing.expect(!model.isCycleActive());
}
